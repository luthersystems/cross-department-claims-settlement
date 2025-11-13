// Copyright © 2024 Luther Systems, Ltd. All right reserved.
package main

import (
	"github.com/luthersystems/cdcs/api"
	"github.com/luthersystems/cdcs/portal/oracle"
	"github.com/luthersystems/cdcs/portal/version"
	svc "github.com/luthersystems/svc/oracle"
)

type startCmd struct {
	baseCmd
	ListenAddress   string `short:"l" help:"Address to listen on" default:":8080" env:"CDCS_ORACLE_LISTEN_ADDRESS"`
	GatewayEndpoint string `short:"g" help:"URL for shiroclient gateway" env:"CDCS_ORACLE_GATEWAY_ENDPOINT"`
	OTLPEndpoint    string `short:"o" help:"URL for OTLP provider" env:"CDCS_ORACLE_OTLP_ENDPOINT"`
	PhylumPath      string `short:"p" help:"Phylum path for in-memory mode" default:"./phylum" env:"CDCS_ORACLE_PHYLUM_PATH"`
	Verbose         bool   `short:"v" help:"Verbose logging" default:"false" env:"CDCS_ORACLE_VERBOSE"`
	EmulateCC       bool   `short:"e" help:"Enable in-memory-mode" default:"false" env:"CDCS_ORACLE_EMULATE_CC"`
}

func (r *startCmd) Run() error {
	cfg := svc.DefaultConfig()
	cfg.PhylumServiceName = "cdcs"
	cfg.ServiceName = "cdcs-oracle"
	cfg.Version = version.Version
	cfg.PhylumPath = r.PhylumPath
	cfg.SetOTLPEndpoint(r.OTLPEndpoint)
	cfg.SetSwaggerHandler(api.SwaggerHandlerOrPanic("v1/oracle"))
	cfg.ListenAddress = r.ListenAddress
	cfg.GatewayEndpoint = r.GatewayEndpoint
	cfg.Verbose = r.Verbose
	cfg.EmulateCC = r.EmulateCC

	return oracle.Run(r.ctx, &oracle.Config{
		Config: *cfg,
	})
}
