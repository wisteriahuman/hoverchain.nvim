package model

import "net/http"

// Client belongs to model, not other.
type Client struct {
	Embedded
	HTTP *http.Client
}

type Embedded struct{}

// Promoted is inherited by Client through embedding.
func (Embedded) Promoted() int { return 1 }

// List returns an API request.
func (*Client) List() *Request { return nil }

// Request belongs to model.
type Request struct{}

// Do returns a response. See [http.Response].
func (*Request) Do() *http.Response { return nil }
