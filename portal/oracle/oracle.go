// Copyright © 2024 Luther Systems, Ltd. All right reserved.

// Package oracle implements the cdcs UI portal.
package oracle

import (
	"context"
	"fmt"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	srv "github.com/luthersystems/cdcs/api/srvpb/v1"
	"github.com/luthersystems/svc/oracle"
	"google.golang.org/grpc"
)

// Config configures the portal.
type Config struct {
	oracle.Config
}

type portal struct {
	srv.UnimplementedCdcsServiceServer
	orc *oracle.Oracle
}

func (p *portal) RegisterServiceServer(grpcServer *grpc.Server) {
	srv.RegisterCdcsServiceServer(grpcServer, p)
}

func (p *portal) RegisterServiceClient(ctx context.Context, grpcConn *grpc.ClientConn, mux *runtime.ServeMux) error {
	return srv.RegisterCdcsServiceHandlerClient(ctx, mux, srv.NewCdcsServiceClient(grpcConn))
}

// Run starts an oracle and blocks the caller until it completes.
func Run(ctx context.Context, config *Config) error {
	if orc, err := oracle.NewOracle(&config.Config); err != nil {
		return fmt.Errorf("new oracle: %w", err)
	} else {
		return orc.StartGateway(ctx, &portal{orc: orc})
	}
}
