package host

import "testing"

// The hook's agent list has one source: every local agent's command, then
// opencode, in that order.
func TestRoutedAgentProgramsListEveryLocalAgentAndOpenCode(t *testing.T) {
	programs := RoutedAgentPrograms()
	if len(programs) != len(localAgentSpecs)+1 || programs[len(programs)-1] != "opencode" {
		t.Fatalf("%q", programs)
	}
	for index, spec := range localAgentSpecs {
		if programs[index] != spec.program {
			t.Fatalf("%q: %d is not %s", programs, index, spec.program)
		}
	}
	for _, program := range programs {
		if _, ok := routedProgram(program); !ok {
			t.Errorf("the host takes no registration of %s", program)
		}
	}
	programs[0] = "changed"
	if RoutedAgentPrograms()[0] == "changed" {
		t.Fatal("the list is shared")
	}
}
