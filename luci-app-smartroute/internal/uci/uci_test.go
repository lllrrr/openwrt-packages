package uci

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	ss, err := Parse(`smartroute.main=global
smartroute.main.enabled='1'
smartroute.cfg01=device
smartroute.cfg01.name='it'\''s mine'
smartroute.cfg01.group='g1' 'g 2'
`)
	if err != nil {
		t.Fatal(err)
	}
	if len(ss) != 2 || ss[0].Type != "global" || !ss[0].Bool("enabled", false) {
		t.Fatalf("sections: %+v", ss)
	}
	if got := ss[1].Get("name"); got != "it's mine" {
		t.Errorf("name = %q", got)
	}
	if got := ss[1].Opts["group"]; !reflect.DeepEqual(got, []string{"g1", "g 2"}) {
		t.Errorf("group = %q", got)
	}
}
