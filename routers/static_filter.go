// Copyright 2021 The Casdoor Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package routers

import (
	"compress/gzip"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/beego/beego/v2/core/logs"
	"github.com/beego/beego/v2/server/web/context"
	"github.com/casdoor/casdoor/conf"
	"github.com/casdoor/casdoor/object"
	"github.com/casdoor/casdoor/util"
)

var (
	oldStaticBaseUrl  = "https://cdn.casbin.org"
	staticBaseUrlConf = conf.GetConfigString("staticBaseUrl")
	staticBaseUrlMode = conf.GetConfigString("staticBaseUrlMode")
	enableGzip        = conf.GetConfigBool("enableGzip")
	frontendBaseDir   = conf.GetConfigString("frontendBaseDir")
)

// getStaticBaseUrl returns the prefix for the frontend's static assets. It
// follows the domain of the current request so that assets are always
// same-origin with the page, which makes deployment-injected staticBaseUrl
// values (e.g. Dokploy's STATIC_BASE_URL) ineffective by design. Set
// staticBaseUrlMode = "config" to fall back to the staticBaseUrl config.
func getStaticBaseUrl(r *http.Request) string {
	if staticBaseUrlMode == "config" && staticBaseUrlConf != "" {
		return staticBaseUrlConf
	}

	// Only r.Host is used: the reverse proxy routes by Host, so it is trusted,
	// while X-Forwarded-Host can be spoofed and would end up embedded in the
	// response body.
	return fmt.Sprintf("%s://%s", getRequestScheme(r), r.Host)
}

func getRequestScheme(r *http.Request) string {
	// Traefik terminates TLS and forwards plain HTTP, so r.TLS is nil here.
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		if i := strings.Index(proto, ","); i != -1 {
			proto = proto[:i]
		}
		return strings.TrimSpace(proto)
	}
	if r.TLS != nil {
		return "https"
	}

	// Same heuristic as object.getOriginFromHostInternal()
	hostname := removePort(r.Host)
	if !strings.Contains(hostname, ".") || net.ParseIP(hostname) != nil {
		return "http"
	}
	return "https"
}

func getWebBuildFolder() string {
	path := "web/build"
	if util.FileExist(filepath.Join(path, "index.html")) || frontendBaseDir == "" {
		return path
	}

	if util.FileExist(filepath.Join(frontendBaseDir, "index.html")) {
		return frontendBaseDir
	}

	path = filepath.Join(frontendBaseDir, "web/build")
	if util.FileExist(filepath.Join(path, "index.html")) {
		return path
	}

	casdoorDir := filepath.Join(filepath.Dir(frontendBaseDir), "casdoor")
	if util.FileExist(filepath.Join(casdoorDir, "index.html")) {
		return casdoorDir
	}
	if util.FileExist(filepath.Join(casdoorDir, "web/build", "index.html")) {
		return filepath.Join(casdoorDir, "web/build")
	}

	return path
}

func fastAutoSignin(ctx *context.Context) (string, error) {
	userId := getSessionUser(ctx)
	if userId == "" {
		return "", nil
	}

	clientId := ctx.Input.Query("client_id")
	responseType := ctx.Input.Query("response_type")
	redirectUri := ctx.Input.Query("redirect_uri")
	scope := ctx.Input.Query("scope")
	state := ctx.Input.Query("state")
	nonce := ctx.Input.Query("nonce")
	codeChallenge := ctx.Input.Query("code_challenge")
	resource := ctx.Input.Query("resource")
	if clientId == "" || responseType != "code" || redirectUri == "" {
		return "", nil
	}

	application, err := object.GetApplicationByClientId(clientId)
	if err != nil {
		return "", err
	}
	if application == nil {
		return "", nil
	}

	if !application.EnableAutoSignin {
		return "", nil
	}

	isAllowed, err := object.CheckLoginPermission(userId, application)
	if err != nil {
		return "", err
	}

	if !isAllowed {
		return "", nil
	}

	user, err := object.GetUser(userId)
	if err != nil {
		return "", err
	}
	if user == nil {
		return "", nil
	}

	consentRequired, err := object.CheckConsentRequired(user, application, scope)
	if err != nil {
		return "", err
	}

	if consentRequired {
		return "", nil
	}

	code, err := object.GetOAuthCode(userId, clientId, "", "autoSignin", responseType, redirectUri, scope, state, nonce, codeChallenge, resource, ctx.Request.Host, getAcceptLanguage(ctx))
	if err != nil {
		return "", err
	} else if code.Message != "" {
		return "", errors.New(code.Message)
	}

	sep := "?"
	if strings.Contains(redirectUri, "?") {
		sep = "&"
	}
	res := fmt.Sprintf("%s%scode=%s&state=%s", redirectUri, sep, code.Code, state)
	return res, nil
}

func StaticFilter(ctx *context.Context) {
	urlPath := ctx.Request.URL.Path

	if urlPath == "/.well-known/acme-challenge/filename" {
		http.ServeContent(ctx.ResponseWriter, ctx.Request, "acme-challenge", time.Now(), strings.NewReader("content"))
	}

	if strings.HasPrefix(urlPath, "/api/") || strings.HasPrefix(urlPath, "/.well-known/") {
		return
	}
	if serveAuthCallbackHandlerScript(ctx) {
		return
	}
	if serveProviderHintRedirectScript(ctx) {
		return
	}
	if strings.HasPrefix(urlPath, "/cas") && (strings.HasSuffix(urlPath, "/serviceValidate") || strings.HasSuffix(urlPath, "/proxy") || strings.HasSuffix(urlPath, "/proxyValidate") || strings.HasSuffix(urlPath, "/validate") || strings.HasSuffix(urlPath, "/p3/serviceValidate") || strings.HasSuffix(urlPath, "/p3/proxyValidate") || strings.HasSuffix(urlPath, "/samlValidate")) {
		return
	}
	if strings.HasPrefix(urlPath, "/scim") {
		return
	}

	if urlPath == "/login/oauth/authorize" {
		redirectUrl, err := fastAutoSignin(ctx)
		if err != nil {
			responseError(ctx, err.Error())
			return
		}

		if redirectUrl != "" {
			http.Redirect(ctx.ResponseWriter, ctx.Request, redirectUrl, http.StatusFound)
			return
		}

		if serveProviderHintRedirectPage(ctx) {
			return
		}
	}

	if serveAuthCallbackPage(ctx) {
		return
	}

	webBuildFolder := getWebBuildFolder()
	path := webBuildFolder
	if urlPath == "/" {
		path += "/index.html"
	} else {
		path += urlPath
	}

	// Preventing synchronization problems from concurrency
	ctx.Input.CruSession = nil

	organizationThemeCookie, err := appendThemeCookie(ctx, urlPath)
	if err != nil {
		fmt.Println(err)
	}

	if strings.Contains(path, "/../") || !util.FileExist(path) {
		path = webBuildFolder + "/index.html"
	}
	if strings.HasSuffix(path, "/index.html") {
		err = util.AppendWebConfigCookie(ctx)
		if err != nil {
			logs.Error("AppendWebConfigCookie failed in StaticFilter, error: %s", err)
		}
	}
	if !util.FileExist(path) {
		dir, err := os.Getwd()
		if err != nil {
			panic(err)
		}
		dir = strings.ReplaceAll(dir, "\\", "/")
		ctx.ResponseWriter.WriteHeader(http.StatusNotFound)
		errorText := fmt.Sprintf("The Casdoor frontend HTML file: \"index.html\" was not found, it should be placed at: \"%s/web/build/index.html\". For more information, see: https://casdoor.org/docs/basic/server-installation/#frontend-1", dir)
		http.ServeContent(ctx.ResponseWriter, ctx.Request, "Casdoor frontend has encountered error...", time.Now(), strings.NewReader(errorText))
		return
	}

	makeGzipResponse(ctx.ResponseWriter, ctx.Request, path, organizationThemeCookie)
}

func serveFileWithReplace(w http.ResponseWriter, r *http.Request, name string, organizationThemeCookie *OrganizationThemeCookie) {
	f, err := os.Open(filepath.Clean(name))
	if err != nil {
		panic(err)
	}
	defer f.Close()

	d, err := f.Stat()
	if err != nil {
		panic(err)
	}

	oldContent := util.ReadStringFromPath(name)
	newContent := oldContent
	if organizationThemeCookie != nil {
		newContent = strings.ReplaceAll(newContent, "https://cdn.casbin.org/img/favicon.png", organizationThemeCookie.Favicon)
		newContent = strings.ReplaceAll(newContent, "<title>Casdoor</title>", fmt.Sprintf("<title>%s</title>", organizationThemeCookie.DisplayName))
	}

	// Set the correct <html lang="..."> on the initial HTML response so browsers
	// do not mis-detect the page language (e.g. Chrome offering to translate a
	// Chinese page into Chinese because the static shell declares lang="en").
	if strings.HasSuffix(name, "index.html") {
		lang := getIndexHtmlLanguage(r)
		newContent = strings.ReplaceAll(newContent, `<html lang="en">`, fmt.Sprintf(`<html lang="%s">`, lang))
	}

	newContent = strings.ReplaceAll(newContent, oldStaticBaseUrl, getStaticBaseUrl(r))

	http.ServeContent(w, r, d.Name(), d.ModTime(), strings.NewReader(newContent))
}

type gzipResponseWriter struct {
	http.ResponseWriter
	gz      *gzip.Writer
	useGzip bool
}

func (w *gzipResponseWriter) WriteHeader(code int) {
	if code == http.StatusNotModified || code == http.StatusPartialContent {
		// These carry no body of ours, so the gzip stream must never start:
		// otherwise gz.Close() emits a header/footer that net/http rejects
		// for such a status. 206 additionally cannot be gzipped at all, since
		// its Content-Range addresses the uncompressed bytes.
		w.useGzip = false
		w.Header().Del("Content-Encoding")
	} else {
		// Defensive: http.ServeContent skips Content-Length while
		// Content-Encoding is set, but any value that did survive would
		// describe the uncompressed size and truncate the response.
		w.Header().Del("Content-Length")
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *gzipResponseWriter) Write(b []byte) (int, error) {
	if !w.useGzip {
		return w.ResponseWriter.Write(b)
	}
	return w.gz.Write(b)
}

func makeGzipResponse(w http.ResponseWriter, r *http.Request, path string, organizationThemeCookie *OrganizationThemeCookie) {
	// Range requests are served uncompressed: the byte offsets http.ServeContent
	// computes address the raw content, not the gzip stream.
	if !enableGzip || !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") || r.Header.Get("Range") != "" {
		serveFileWithReplace(w, r, path, organizationThemeCookie)
		return
	}

	w.Header().Set("Content-Encoding", "gzip")
	gz := gzip.NewWriter(w)
	gzw := &gzipResponseWriter{ResponseWriter: w, gz: gz, useGzip: true}
	// A gzip.Writer emits nothing until its first Write or Close, so skipping
	// Close on the 304 path leaves the response body genuinely empty.
	defer func() {
		if gzw.useGzip {
			gz.Close()
		}
	}()

	serveFileWithReplace(gzw, r, path, organizationThemeCookie)
}
