package main

import (
	api "example.com/hoverchain-tests/model"
	"example.com/hoverchain-tests/other"
	"net/http"
)

// Box holds an HTTP client and an API client.
type Box struct {
	HTTP  *http.Client
	API   *api.Client
	Other *other.Client
}

// Read returns an HTTP response.
func (b *Box) Read() *http.Response { return nil }

func main() {
	b := &Box{}
	_ = b.API
}
