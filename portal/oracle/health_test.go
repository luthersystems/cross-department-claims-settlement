// Copyright © 2026 Luther Systems, Ltd. All right reserved.

package oracle

import (
	"context"
	"testing"

	healthcheck "buf.build/gen/go/luthersystems/protos/protocolbuffers/go/healthcheck/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestHealthCheckPhylumReport checks that the oracle's health check carries
// the phylum's report under the name start.go gives PhylumServiceName. The
// phylum defines no healthcheck endpoint: the router's endpoint reports the
// name that main.lisp gives router:set-service-info.
func TestHealthCheckPhylumReport(t *testing.T) {
	server := makeTestServer(t)
	resp, err := server.orc.GetHealthCheck(context.Background(), &healthcheck.GetHealthCheckRequest{})
	require.NoError(t, err)
	var found bool
	for _, r := range resp.GetReports() {
		if r.GetServiceName() == "cdcs" {
			found = true
			assert.Equal(t, "UP", r.GetStatus())
			assert.NotEmpty(t, r.GetServiceVersion())
		}
	}
	assert.True(t, found, "no report named cdcs: %v", resp.GetReports())
}
