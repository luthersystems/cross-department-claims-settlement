package oracle

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/uuid"
	pb "github.com/luthersystems/cdcs/api/pb/v1"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient/private"
	"github.com/luthersystems/svc/oracle"
	"github.com/luthersystems/svc/svcerr"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/structpb"
)

// The claim process is one defflow, claim, in phylum/claim.lisp.  defflow
// generates its endpoints:
//
//	claim_start request_key req
//	claim_get run_id
//	claim_<input> run_id input gen [request_key]
//
// An input call must send the run's current generation, so that an input
// meant for an earlier step cannot land on a later one.  A webhook sender
// does not know the generation, so each input RPC here reads claim_get
// first, checks that the claim waits at that input, and sends the
// generation it read.  This is why the webhooks come to the portal and not
// to connectorhub inbound REST connectors.
//
// The phylum checks every input again.  The portal checks first because
// the phylum client hides a refusal's reason ("unknown phylum error") when
// the phylum answers with a map, and a defflow refusal is a map.  So the
// caller gets the reason from the portal; only a race between two inputs
// for the same step reaches the phylum's refusal.

const claimFlow = "claim"

func (p *portal) defaultConfigs(_ context.Context) []shiroclient.Config {
	cfg, err := private.WithSeed()
	if err != nil {
		panic(err)
	}
	return append([]shiroclient.Config{cfg}, p.extraConfigs...)
}

// flowRun is a run as the generated defflow endpoints report it: run_id,
// state, gen, label, and for claim_get also result, error and vars.  It is
// read as a Struct, not a fixed message, because the run view carries more
// fields than the portal uses and gains fields between substrate versions.
type flowRun struct{ *structpb.Struct }

func (r flowRun) str(key string) string { return r.GetFields()[key].GetStringValue() }

// gen is the run's generation, which an input call must send back.  JSON
// carries it as a number.
func (r flowRun) gen() int64 { return int64(r.GetFields()["gen"].GetNumberValue()) }

// callFlow calls a generated defflow endpoint with positional params and
// returns the run it reports.  oracle.Call sends its request message as the
// one param; the WithParams config comes after it and replaces the params,
// because the generated endpoints take positional args.
func (p *portal) callFlow(ctx context.Context, method string, params ...any) (flowRun, error) {
	configs := append(p.defaultConfigs(ctx), shiroclient.WithParams(params))
	run, err := oracle.Call(p.orc, ctx, method, &emptypb.Empty{}, &structpb.Struct{}, configs...)
	return flowRun{run}, err
}

// claim turns a flow run into the API's Claim.
func (r flowRun) claim() *pb.Claim {
	f := r.GetFields()
	claim := &pb.Claim{
		ClaimId: r.str("run_id"),
		State:   r.str("state"),
		Step:    r.str("label"),
		Result:  f["result"].GetStructValue(),
		Error:   f["error"],
	}
	if vars := f["vars"].GetStructValue(); vars != nil {
		claim.Details = vars.GetFields()["claim"].GetStructValue()
	}
	return claim
}

// missing returns "missing a, b" for the named fields that are blank, or "".
func missing(fields ...[2]string) string {
	var names []string
	for _, f := range fields {
		if strings.TrimSpace(f[1]) == "" {
			names = append(names, f[0])
		}
	}
	if len(names) == 0 {
		return ""
	}
	return "missing " + strings.Join(names, ", ")
}

// StartClaim starts a claim.  The phylum checks the request too; the portal
// checks first so the caller sees which field is missing.
func (p *portal) StartClaim(ctx context.Context, req *pb.StartClaimRequest) (*pb.StartClaimResponse, error) {
	if problem := missing(
		[2]string{"policy_id", req.GetPolicyId()},
		[2]string{"guidewire_claim_id", req.GetGuidewireClaimId()},
		[2]string{"invoice_amount", req.GetInvoiceAmount()},
		[2]string{"signer_name", req.GetSignerName()},
		[2]string{"signer_email", req.GetSignerEmail()},
	); problem != "" {
		return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	key := req.GetRequestKey()
	if key == "" {
		key = uuid.NewString()
	}
	start := map[string]string{
		"policy_id":          req.GetPolicyId(),
		"guidewire_claim_id": req.GetGuidewireClaimId(),
		"invoice_amount":     req.GetInvoiceAmount(),
		"signer_name":        req.GetSignerName(),
		"signer_email":       req.GetSignerEmail(),
		"originator_name":    req.GetOriginatorName(),
		"recipient_name":     req.GetRecipientName(),
		"issue_date":         req.GetIssueDate(),
	}
	run, err := p.callFlow(ctx, claimFlow+"_start", key, start)
	if err != nil {
		return nil, fmt.Errorf("start claim: %w", err)
	}
	return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Claim{Claim: run.claim()}}, nil
}

// GetClaim reads a claim.
func (p *portal) GetClaim(ctx context.Context, req *pb.GetClaimRequest) (*pb.GetClaimResponse, error) {
	if problem := missing([2]string{"claim_id", req.GetClaimId()}); problem != "" {
		return &pb.GetClaimResponse{Result: &pb.GetClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	run, err := p.callFlow(ctx, claimFlow+"_get", req.GetClaimId())
	if err != nil {
		return nil, fmt.Errorf("get claim: %w", err)
	}
	return &pb.GetClaimResponse{Result: &pb.GetClaimResponse_Claim{Claim: run.claim()}}, nil
}

// sendInput sends input to the claim when it waits at label.  It returns the
// claim, or a reason the input was refused.
func (p *portal) sendInput(ctx context.Context, claimID, label, requestKey string, input map[string]string) (*pb.Claim, string, error) {
	run, err := p.callFlow(ctx, claimFlow+"_get", claimID)
	if err != nil {
		return nil, "", fmt.Errorf("get claim: %w", err)
	}
	if run.str("state") != "waiting" || run.str("label") != label {
		return nil, fmt.Sprintf("claim %s is %s at %q, not waiting for %s", claimID, run.str("state"), run.str("label"), label), nil
	}
	method := claimFlow + "_" + strings.ReplaceAll(label, "-", "_")
	params := []any{claimID, input, run.gen()}
	if requestKey != "" {
		params = append(params, requestKey)
	}
	run, err = p.callFlow(ctx, method, params...)
	if err != nil {
		return nil, "", fmt.Errorf("%s: %w", method, err)
	}
	return run.claim(), "", nil
}

// ContractSigned resumes a claim that waits for its signed contract.
func (p *portal) ContractSigned(ctx context.Context, req *pb.ContractSignedRequest) (*pb.ContractSignedResponse, error) {
	if problem := missing([2]string{"claim_id", req.GetClaimId()}, [2]string{"signed_by", req.GetSignedBy()}); problem != "" {
		return &pb.ContractSignedResponse{Result: &pb.ContractSignedResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	claim, refused, err := p.sendInput(ctx, req.GetClaimId(), "contract-signed", req.GetRequestKey(),
		map[string]string{"signed_by": req.GetSignedBy()})
	if err != nil {
		return nil, err
	}
	if refused != "" {
		return &pb.ContractSignedResponse{Result: &pb.ContractSignedResponse_Exception{Exception: svcerr.BusinessException(ctx, refused)}}, nil
	}
	return &pb.ContractSignedResponse{Result: &pb.ContractSignedResponse_Claim{Claim: claim}}, nil
}

// PaymentApproved resumes a claim that waits for the payment team.
func (p *portal) PaymentApproved(ctx context.Context, req *pb.PaymentApprovedRequest) (*pb.PaymentApprovedResponse, error) {
	if problem := missing([2]string{"claim_id", req.GetClaimId()}, [2]string{"signed_by", req.GetSignedBy()}); problem != "" {
		return &pb.PaymentApprovedResponse{Result: &pb.PaymentApprovedResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	claim, refused, err := p.sendInput(ctx, req.GetClaimId(), "payment-approved", req.GetRequestKey(),
		map[string]string{"signed_by": req.GetSignedBy()})
	if err != nil {
		return nil, err
	}
	if refused != "" {
		return &pb.PaymentApprovedResponse{Result: &pb.PaymentApprovedResponse_Exception{Exception: svcerr.BusinessException(ctx, refused)}}, nil
	}
	return &pb.PaymentApprovedResponse{Result: &pb.PaymentApprovedResponse_Claim{Claim: claim}}, nil
}

// PaymentStatus gives a claim the payment status from ABS.
func (p *portal) PaymentStatus(ctx context.Context, req *pb.PaymentStatusRequest) (*pb.PaymentStatusResponse, error) {
	problem := missing([2]string{"claim_id", req.GetClaimId()}, [2]string{"payment_id", req.GetPaymentId()},
		[2]string{"status", req.GetStatus()})
	if problem == "" {
		switch strings.ToLower(req.GetStatus()) {
		case "approved", "rejected", "pending":
		default:
			problem = fmt.Sprintf("status %q is not approved, rejected or pending", req.GetStatus())
		}
	}
	if problem != "" {
		return &pb.PaymentStatusResponse{Result: &pb.PaymentStatusResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	claim, refused, err := p.sendInput(ctx, req.GetClaimId(), "payment-status", req.GetRequestKey(),
		map[string]string{"payment_id": req.GetPaymentId(), "status": req.GetStatus()})
	if err != nil {
		return nil, err
	}
	if refused != "" {
		return &pb.PaymentStatusResponse{Result: &pb.PaymentStatusResponse_Exception{Exception: svcerr.BusinessException(ctx, refused)}}, nil
	}
	return &pb.PaymentStatusResponse{Result: &pb.PaymentStatusResponse_Claim{Claim: claim}}, nil
}
