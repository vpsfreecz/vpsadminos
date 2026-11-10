package reposerver

import (
	"net/http"
	"strings"
	"testing"
)

func TestDashboardPageRouteDispatch(t *testing.T) {
	observer := &HTTPObserver{queue: make(chan AccessEvent, 16)}
	h := NewHTTPHandler(newFixtureReader(t), HTTPOptions{Repository: "repo", Observer: observer})
	for _, path := range []string{"/usage", "/images", "/status"} {
		get := requestHTTP(h, http.MethodGet, path, nil)
		if get.Code != http.StatusOK || !strings.HasPrefix(get.Header().Get("Content-Type"), "text/html") || get.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("path=%s status=%d headers=%v", path, get.Code, get.Header())
		}
		head := requestHTTP(h, http.MethodHead, path, nil)
		if head.Code != get.Code || head.Body.Len() != 0 || head.Header().Get("Content-Length") != get.Header().Get("Content-Length") {
			t.Fatal(path, head.Code, head.Header(), head.Body.Len())
		}
		for range 2 {
			event := <-observer.queue
			if event.Kind != "dashboard" || event.Scope != "public" || event.Path != path {
				t.Fatal(event)
			}
		}
		post := requestHTTP(h, http.MethodPost, path, nil)
		if post.Code != http.StatusMethodNotAllowed || post.Header().Get("Allow") != "GET, HEAD" {
			t.Fatal(path, post.Code, post.Header())
		}
		<-observer.queue
	}
	for _, path := range []string{"/runs/sealed/usage", "/runs/sealed/images", "/runs/sealed/status", "/images/unknown"} {
		if response := requestHTTP(h, http.MethodGet, path, nil); response.Code != http.StatusNotFound {
			t.Fatal(path, response.Code)
		}
	}
}
