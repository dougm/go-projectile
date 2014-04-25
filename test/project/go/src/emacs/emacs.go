package emacs

func init() {

}

type Foo struct {
	Name string
}

func Bar(one, two, three string) int {
	return len(one) + len(two) + len(three)
}
