package oracle

import (
	"context"
	"fmt"

	pb "github.com/luthersystems/cdcs/api/pb/v1"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient/private"
	"github.com/luthersystems/svc/oracle"
)

func (p *portal) defaultConfigs(_ context.Context) []shiroclient.Config {
	cfg, err := private.WithSeed()
	if err != nil {
		panic(err)
	}
	return []shiroclient.Config{cfg}
}

// // GetHealthCheck returns health status.
// func (p *portal) GetHealthCheck(ctx context.Context, req *healthcheck.GetHealthCheckRequest) (*healthcheck.GetHealthCheckResponse, error) {
// 	return p.orc.GetHealthCheck(ctx, req)
// }

// // CreateClaim is an example resource creation endpoint.
// func (p *portal) CreateClaim(ctx context.Context, req *pb.CreateClaimRequest) (*pb.CreateClaimResponse, error) {
// 	// Example trace without elps filtering (includes all spans)
// 	ctx, span := p.orc.TraceContext(ctx, "CreateClaim")
// 	defer span()
// 	ctx, err := opttrace.TraceContextWithoutELPSFilter(ctx)
// 	if err != nil {
// 		p.orc.Log(ctx).WithError(err).Warn("tracing disabled")
// 	}
// 	return oracle.Call(p.orc, ctx, "create_claim", req, &pb.CreateClaimResponse{}, p.defaultConfigs(ctx)...)
// }

// // AddClaimant is an example resource update endpoint.
// func (p *portal) AddClaimant(ctx context.Context, req *pb.AddClaimantRequest) (*pb.AddClaimantResponse, error) {
// 	// Normal tracing enabled, WITH elps filtering.
// 	return oracle.Call(p.orc, ctx, "add_claimant", req, &pb.AddClaimantResponse{}, p.defaultConfigs(ctx)...)
// }

// // GetClaim is an example query endpoint.
// func (p *portal) GetClaim(ctx context.Context, req *pb.GetClaimRequest) (*pb.GetClaimResponse, error) {
// 	return oracle.Call(p.orc, ctx, "get_claim", req, &pb.GetClaimResponse{})
// }

func (p *portal) UploadClaimWF1(ctx context.Context, req *pb.UploadClaimWF1Request) (*pb.UploadClaimWF1Response, error) {
	fmt.Printf("ProcessInvoiceWF1 payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "upload_claim_wf1", req, &pb.UploadClaimWF1Response{}, p.defaultConfigs(ctx)...)
}

func (p *portal) UploadClaimWF2(ctx context.Context, req *pb.UploadClaimWF2Request) (*pb.UploadClaimWF2Response, error) {
	fmt.Printf("ProcessInvoiceWF2 payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "upload_claim_wf2", req, &pb.UploadClaimWF2Response{}, p.defaultConfigs(ctx)...)
}

func (p *portal) UploadClaimWF3(ctx context.Context, req *pb.UploadClaimWF3Request) (*pb.UploadClaimWF3Response, error) {
	fmt.Printf("ProcessInvoiceWF3 payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "upload_claim_wf3", req, &pb.UploadClaimWF3Response{}, p.defaultConfigs(ctx)...)
}

func (p *portal) UploadClaimWF4(ctx context.Context, req *pb.UploadClaimWF4Request) (*pb.UploadClaimWF4Response, error) {
	fmt.Printf("ProcessInvoiceWF4 payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "upload_claim_wf4", req, &pb.UploadClaimWF4Response{}, p.defaultConfigs(ctx)...)
}

func (p *portal) UploadClaimWF5(ctx context.Context, req *pb.UploadClaimWF5Request) (*pb.UploadClaimWF5Response, error) {
	fmt.Printf("ProcessInvoiceWF5 payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "upload_claim_wf5", req, &pb.UploadClaimWF5Response{}, p.defaultConfigs(ctx)...)
}

func (p *portal) InvokeProcess(ctx context.Context, req *pb.InvokeProcessRequest) (*pb.InvokeProcessResponse, error) {
	fmt.Printf("InvokeProcess payload: %+v\n", req)
	return oracle.Call(p.orc, ctx, "invoke_process", req, &pb.InvokeProcessResponse{}, p.defaultConfigs(ctx)...)
}
