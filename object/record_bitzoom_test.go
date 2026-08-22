package object

import "testing"

func TestDeletedWebhookUserSnapshot(t *testing.T) {
	valid := &Record{
		Action:       "delete-user",
		Organization: "bitzoom",
		User:         "alice",
		Object:       `{"id":"platform-alice","owner":"bitzoom","name":"alice","signupApplication":"futures"}`,
	}

	user, err := deletedWebhookUserSnapshot(valid)
	if err != nil {
		t.Fatalf("deleted snapshot: %v", err)
	}
	if user == nil || user.Id != "platform-alice" || user.Owner != "bitzoom" || user.Name != "alice" || user.SignupApplication != "futures" {
		t.Fatalf("unexpected deleted snapshot: %#v", user)
	}

	tests := []struct {
		name   string
		record *Record
	}{
		{name: "non delete event", record: &Record{Action: "update-user", Organization: "bitzoom", User: "alice", Object: valid.Object}},
		{name: "identity mismatch", record: &Record{Action: "delete-user", Organization: "bitzoom", User: "bob", Object: valid.Object}},
		{name: "missing stable id", record: &Record{Action: "delete-user", Organization: "bitzoom", User: "alice", Object: `{"owner":"bitzoom","name":"alice","signupApplication":"futures"}`}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if user, err := deletedWebhookUserSnapshot(test.record); err == nil || user != nil {
				t.Fatalf("snapshot=(%#v,%v), want fail closed", user, err)
			}
		})
	}
}
