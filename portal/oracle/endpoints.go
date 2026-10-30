package oracle

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	pb "github.com/luthersystems/cdcs/api/pb/v1"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient/phylum"
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
// The phylum checks every input again; only a race between two inputs for
// the same step reaches its refusal.  The portal answers a defflow refusal
// (an unknown claim, an input the claim is not waiting for) as a business
// exception, not an internal error, so a webhook sender does not retry it.

const claimFlow = "claim"

// refusal returns the code ("not-found", "not-waiting", ...) and message of
// a defflow refusal.  A refusal is phylum error data
// {"error": CODE, "message": TEXT}; the phylum client masks it in Error()
// and keeps it in *phylum.Error (shiroclient-sdk-go#90).
func refusal(err error) (code, message string, ok bool) {
	var pe *phylum.Error
	if !errors.As(err, &pe) {
		return "", "", false
	}
	var data struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if json.Unmarshal(pe.DataJSON(), &data) != nil || data.Error == "" {
		return "", "", false
	}
	if data.Message == "" {
		// A caller treats an empty reason as success.
		data.Message = data.Error
	}
	return data.Error, data.Message, true
}

// startRequiredFields are the start request fields the flow needs.  They
// must match claim-required-fields in phylum/claim-steps.lisp
// (TestStartRequiredFieldsMatchPhylum).
var startRequiredFields = []string{"policy_id", "guidewire_claim_id", "invoice_amount", "signer_name", "signer_email"}

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

// missing returns "missing a, b" for the named fields of m that are blank,
// or "".
func missing(m map[string]string, names ...string) string {
	var blank []string
	for _, name := range names {
		if strings.TrimSpace(m[name]) == "" {
			blank = append(blank, name)
		}
	}
	if len(blank) == 0 {
		return ""
	}
	return "missing " + strings.Join(blank, ", ")
}

// StartClaim starts a claim.  The phylum checks the request too; the portal
// checks first so the caller sees which field is missing.
func (p *portal) StartClaim(ctx context.Context, req *pb.StartClaimRequest) (*pb.StartClaimResponse, error) {
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
	if problem := missing(start, startRequiredFields...); problem != "" {
		return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	key := req.GetRequestKey()
	if key == "" {
		key = uuid.NewString()
	}
	run, err := p.callFlow(ctx, claimFlow+"_start", key, start)
	if reason, ok := startRejected(err); ok {
		// The phylum checks more than the portal, such as the amount.
		return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, reason)}}, nil
	}
	if _, msg, ok := refusal(err); ok {
		// For example a request key sent again with other fields.
		return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, msg)}}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("start claim: %w", err)
	}
	return &pb.StartClaimResponse{Result: &pb.StartClaimResponse_Claim{Claim: run.claim()}}, nil
}

// GetClaim reads a claim.
func (p *portal) GetClaim(ctx context.Context, req *pb.GetClaimRequest) (*pb.GetClaimResponse, error) {
	if problem := missing(map[string]string{"claim_id": req.GetClaimId()}, "claim_id"); problem != "" {
		return &pb.GetClaimResponse{Result: &pb.GetClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, problem)}}, nil
	}
	run, err := p.callFlow(ctx, claimFlow+"_get", req.GetClaimId())
	if code, msg, ok := refusal(err); ok {
		return &pb.GetClaimResponse{Result: &pb.GetClaimResponse_Exception{Exception: svcerr.BusinessException(ctx, refusedRead(req.GetClaimId(), code, msg))}}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get claim: %w", err)
	}
	return &pb.GetClaimResponse{Result: &pb.GetClaimResponse_Claim{Claim: run.claim()}}, nil
}

// startRejected returns the reason when err is the flow's start rejection.
// A start rejection fails the transaction, so it comes back as the
// transaction's error text, "... start-rejected: {JSON}", not as phylum
// error data (refusal).  The JSON's run.reason is the flow's fail message.
func startRejected(err error) (string, bool) {
	if err == nil {
		return "", false
	}
	text := err.Error()
	i := strings.Index(text, "start-rejected: {")
	if i < 0 {
		return "", false
	}
	var rej struct {
		Run struct {
			Reason string `json:"reason"`
		} `json:"run"`
	}
	if json.Unmarshal([]byte(text[i+len("start-rejected: "):]), &rej) != nil || rej.Run.Reason == "" {
		return "the claim flow rejected the start request", true
	}
	return rej.Run.Reason, true
}

// refusedRead is the reason a claim_get was refused: almost always an
// unknown claim id.
func refusedRead(claimID, code, message string) string {
	if code == "not-found" {
		return fmt.Sprintf("claim %s not found", claimID)
	}
	return message
}

// sendInput sends input to the claim when it waits at label.  It returns the
// claim, or a reason the input was refused.
//
// A webhook sent again after the claim moved on is refused, so it cannot
// apply twice.  Its request key cannot make the resend succeed instead:
// defflow matches an input's request key together with the generation the
// input was accepted at, which the portal no longer knows.
//
// The payment-status step waits at the same label again after "pending", so
// two updates sent close together can read the same generation.  The second
// is refused as stale-generation although the claim still waits for it, and
// a refusal is final to the sender.  So a stale-generation refusal reads the
// claim again and, if it still waits at label, sends the input once more.
func (p *portal) sendInput(ctx context.Context, claimID, label, requestKey string, input map[string]string) (*pb.Claim, string, error) {
	const attempts = 2
	method := claimFlow + "_" + strings.ReplaceAll(label, "-", "_")
	for attempt := 1; ; attempt++ {
		run, err := p.callFlow(ctx, claimFlow+"_get", claimID)
		if code, msg, ok := refusal(err); ok {
			return nil, refusedRead(claimID, code, msg), nil
		}
		if err != nil {
			return nil, "", fmt.Errorf("get claim: %w", err)
		}
		if run.str("state") != "waiting" || run.str("label") != label {
			return nil, fmt.Sprintf("claim %s is %s at %q, not waiting for %s", claimID, run.str("state"), run.str("label"), label), nil
		}
		params := []any{claimID, input, run.gen()}
		if requestKey != "" {
			params = append(params, requestKey)
		}
		run, err = p.callFlow(ctx, method, params...)
		if code, msg, ok := refusal(err); ok {
			if code == "stale-generation" && attempt < attempts {
				continue
			}
			// Another input for this step won the race.
			return nil, msg, nil
		}
		if err != nil {
			return nil, "", fmt.Errorf("%s: %w", method, err)
		}
		return run.claim(), "", nil
	}
}

// ContractSigned resumes a claim that waits for its signed contract.
func (p *portal) ContractSigned(ctx context.Context, req *pb.ContractSignedRequest) (*pb.ContractSignedResponse, error) {
	if problem := missing(map[string]string{"claim_id": req.GetClaimId(), "signed_by": req.GetSignedBy()}, "claim_id", "signed_by"); problem != "" {
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
	if problem := missing(map[string]string{"claim_id": req.GetClaimId(), "signed_by": req.GetSignedBy()}, "claim_id", "signed_by"); problem != "" {
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
	problem := missing(map[string]string{"claim_id": req.GetClaimId(), "payment_id": req.GetPaymentId(), "status": req.GetStatus()},
		"claim_id", "payment_id", "status")
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
