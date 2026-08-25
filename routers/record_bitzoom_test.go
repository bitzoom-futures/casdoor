package routers

import "testing"

func TestUserMutationRecordIdentity(t *testing.T) {
	tests := []struct {
		name       string
		action     string
		body       string
		wantOwner  string
		wantUser   string
		wantTarget bool
	}{
		{name: "application updates target user", action: "update-user", body: `{"owner":"bitzoom","name":"alice","isForbidden":true}`, wantOwner: "bitzoom", wantUser: "alice", wantTarget: true},
		{name: "application deletes target user", action: "delete-user", body: `{"owner":"bitzoom","name":"bob"}`, wantOwner: "bitzoom", wantUser: "bob", wantTarget: true},
		{name: "logout keeps authenticated caller", action: "logout", body: `{}`},
		{name: "malformed mutation remains fail closed", action: "update-user", body: `{"owner":"bitzoom"}`},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			owner, user, ok := userMutationRecordIdentity(test.action, test.body)
			if owner != test.wantOwner || user != test.wantUser || ok != test.wantTarget {
				t.Fatalf("identity=(%q,%q,%t) want (%q,%q,%t)", owner, user, ok, test.wantOwner, test.wantUser, test.wantTarget)
			}
		})
	}
}
