package other

// Client belongs to other, not model.
type Client struct{}

// List must not be confused with model.Client.List.
func (*Client) List() string { return "other" }
