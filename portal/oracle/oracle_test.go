// Copyright © 2021 Luther Systems, Ltd. All right reserved.

// Tests of the claim RPCs against the phylum in a mock substrate.  The mock
// has no connectorhub, so deliverReply answers each connector step the way
// the hub does.  The phylum's flow tests (phylum/claim_test.lisp) cover the
// flow's branches; these cover what the portal adds: the positional params
// of the generated endpoints, the generation it reads and sends back, the
// run it reads, and its own checks.

package oracle

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	pb "github.com/luthersystems/cdcs/api/pb/v1"
	"github.com/luthersystems/shiroclient-sdk-go/shiroclient"
	"github.com/luthersystems/svc/oracle"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/structpb"
)

// phylumRelPath is the path to the phylum dir relative to this file.
const phylumRelPath = "../../phylum"

func makeTestServer(t *testing.T) *portal {
	t.Helper()
	cfg := &Config{Config: *oracle.DefaultConfig()}
	cfg.PhylumPath = phylumRelPath
	orc, stop := oracle.NewTestOracle(t, &cfg.Config)
	t.Cleanup(stop)
	// The claim flow takes starts and inputs from Org1MSP only, the org of
	// the gateway on this network (fabric/fabric-client.yaml).
	return &portal{orc: orc, extraConfigs: []shiroclient.Config{shiroclient.WithCreator("Org1MSP")}}
}

func testStartRequest() *pb.StartClaimRequest {
	return &pb.StartClaimRequest{
		PolicyId:         "POL-8872",
		GuidewireClaimId: "GW-1001",
		InvoiceAmount:    "25000.00",
		SignerName:       "Jack Clarke",
		SignerEmail:      "jack.clarke@example.com",
		RequestKey:       "test-start",
	}
}

func TestStartAndGetClaim(t *testing.T) {
	server := makeTestServer(t)
	ctx := context.Background()

	started, err := server.StartClaim(ctx, testStartRequest())
	require.NoError(t, err)
	require.Nil(t, started.GetException())
	claim := started.GetClaim()
	require.NotEmpty(t, claim.GetClaimId())
	require.Equal(t, "waiting", claim.GetState())
	require.Equal(t, "oracle-claim", claim.GetStep())

	// The same request key returns the same claim, not a second one.
	again, err := server.StartClaim(ctx, testStartRequest())
	require.NoError(t, err)
	require.Equal(t, claim.GetClaimId(), again.GetClaim().GetClaimId())

	got, err := server.GetClaim(ctx, &pb.GetClaimRequest{ClaimId: claim.GetClaimId()})
	require.NoError(t, err)
	require.Nil(t, got.GetException())
	require.Equal(t, "oracle-claim", got.GetClaim().GetStep())
	details := got.GetClaim().GetDetails().GetFields()
	require.Equal(t, claim.GetClaimId(), details["claim_id"].GetStringValue())
	require.Equal(t, "POL-8872", details["policy_id"].GetStringValue())
	require.Equal(t, "Acme Insurance Ltd.", details["originator_name"].GetStringValue())
}

func TestStartClaimNamesMissingFields(t *testing.T) {
	server := makeTestServer(t)
	req := testStartRequest()
	req.SignerEmail = " "
	req.GuidewireClaimId = ""
	resp, err := server.StartClaim(context.Background(), req)
	require.NoError(t, err)
	require.Equal(t, "missing guidewire_claim_id, signer_email", resp.GetException().GetDescription())
}

func TestInputRefusedWhenClaimWaitsElsewhere(t *testing.T) {
	server := makeTestServer(t)
	ctx := context.Background()
	started, err := server.StartClaim(ctx, testStartRequest())
	require.NoError(t, err)
	id := started.GetClaim().GetClaimId()

	signed, err := server.ContractSigned(ctx, &pb.ContractSignedRequest{ClaimId: id, SignedBy: "jack.clarke@example.com"})
	require.NoError(t, err)
	require.Equal(t, `claim `+id+` is waiting at "oracle-claim", not waiting for contract-signed`,
		signed.GetException().GetDescription())

	approved, err := server.PaymentApproved(ctx, &pb.PaymentApprovedRequest{ClaimId: id, SignedBy: "payments@example.com"})
	require.NoError(t, err)
	require.Contains(t, approved.GetException().GetDescription(), "not waiting for payment-approved")

	status, err := server.PaymentStatus(ctx, &pb.PaymentStatusRequest{ClaimId: id, PaymentId: "PAY-1", Status: "Approved"})
	require.NoError(t, err)
	require.Contains(t, status.GetException().GetDescription(), "not waiting for payment-status")
}

func TestInputChecksFieldsFirst(t *testing.T) {
	server := makeTestServer(t)
	ctx := context.Background()

	signed, err := server.ContractSigned(ctx, &pb.ContractSignedRequest{ClaimId: "c1"})
	require.NoError(t, err)
	require.Equal(t, "missing signed_by", signed.GetException().GetDescription())

	status, err := server.PaymentStatus(ctx, &pb.PaymentStatusRequest{ClaimId: "c1", PaymentId: "PAY-1", Status: "done"})
	require.NoError(t, err)
	require.Equal(t, `status "done" is not approved, rejected or pending`, status.GetException().GetDescription())
}

// idDocument is "Claim ID: CLM-4567\nVerified: Yes", base64-encoded as the
// SharePoint connector sends each line.
const idDocument = "Q2xhaW0gSUQ6IENMTS00NTY3ClZlcmlmaWVkOiBZZXM="

// testReplies is the reply each connector step gets, by step, trimmed to
// the fields the readers need.  phylum/claim_testhelpers.lisp holds the
// full mock replies of fabric/connectorhub.yaml.
var testReplies = map[string]any{
	"oracle-claim": map[string]any{"rows": []any{map[string]any{
		"CLAIM_ID": "CLM-4567", "AMOUNT": 2500.0, "STATUS": "UnderReview",
		"CLAIMANT_FIRST_NAME": "John", "CLAIMANT_LAST_NAME": "Doe", "CLAIMANT_DOB": "1980-05-15",
		"CLAIMANT_ADDRESS": "123 Main Street", "CLAIMANT_NATIONAL_ID": "AB123456C"}}},
	"equifax-screening": map[string]any{"equifax": map[string]any{"entity_screening_response": map[string]any{
		"status": "Pass", "pstatus_det": "Clear", "hit_value_pep": 0, "hit_value_emb": 0}}},
	"teams-thread":        map[string]any{"thread_id": "thread-12345", "message_id": "msg-12345"},
	"guidewire-claim":     map[string]any{"status": "UnderReview"},
	"policy-check":        []any{map[string]any{"STATUS": "Active", "COVERAGE_LIMIT": "20000.00"}},
	"id-document":         map[string]any{"type": "text", "content": []any{idDocument}},
	"guidewire-approval":  map[string]any{"approval": "ApprovedForSettlement"},
	"esignature-contract": map[string]any{"data": map[string]any{"data": map[string]any{"contract": map[string]any{"id": "contract-abc123", "status": "pending", "signers": []any{}}}}},
	"salesforce-invoice":  map[string]any{"id": "a0X5g000000XYZ1"},
	"invoice-email":       map[string]any{"status": "sent"},
	"zoho-invoice":        map[string]any{"invoice": map[string]any{"invoice_id": "INV-10001", "invoice_number": "1234567000001", "total": 1250.0}},
	"settlement-document": map[string]any{"type": "text", "line_count": 1},
	"servicenow-incident": map[string]any{"result": map[string]any{"sys_id": "abc123def456", "number": "INC0010001"}},
	"payment-notice":      map[string]any{"status": "updated"},
	"d365fo-journal":      map[string]any{"record": map[string]any{"RecId": "5637144576"}},
	"sap-payment":         map[string]any{"payment": map[string]any{"transaction_id": "SAP-TXN-1001"}},
}

// deliverReply answers the request the claim waits on, as connectorhub
// does: a $ch_callback call whose reply is transient data $ch_rep:0.
func deliverReply(t *testing.T, server *portal, claimID string, value any) {
	t.Helper()
	ctx := context.Background()
	run, err := server.callFlow(ctx, "claim_get", claimID)
	require.NoError(t, err)
	text, err := json.Marshal(value)
	require.NoError(t, err)
	body, err := json.Marshal(map[string]any{
		"request_id": run.str("request_id"),
		"response":   map[string]any{"generic": map[string]any{"text": string(text)}},
	})
	require.NoError(t, err)
	configs := append(server.defaultConfigs(ctx),
		shiroclient.WithParams([]any{map[string]any{}}),
		shiroclient.WithTransientData("$ch_rep:0", body))
	_, err = oracle.Call(server.orc, ctx, "$ch_callback", &emptypb.Empty{}, &structpb.Struct{}, configs...)
	require.NoError(t, err)
}

// answerConnectors answers connector steps until the claim waits for an
// input or ends, and returns the step it stops at.
func answerConnectors(t *testing.T, server *portal, claimID string) string {
	t.Helper()
	for {
		got, err := server.GetClaim(context.Background(), &pb.GetClaimRequest{ClaimId: claimID})
		require.NoError(t, err)
		claim := got.GetClaim()
		reply, ok := testReplies[claim.GetStep()]
		if claim.GetState() != "waiting" || !ok {
			return claim.GetStep()
		}
		deliverReply(t, server, claimID, reply)
	}
}

func TestClaimRunsThroughTheWebhooks(t *testing.T) {
	server := makeTestServer(t)
	ctx := context.Background()
	started, err := server.StartClaim(ctx, testStartRequest())
	require.NoError(t, err)
	id := started.GetClaim().GetClaimId()

	require.Equal(t, "contract-signed", answerConnectors(t, server, id))
	signed, err := server.ContractSigned(ctx, &pb.ContractSignedRequest{ClaimId: id, SignedBy: "jack.clarke@example.com", RequestKey: "sig-1"})
	require.NoError(t, err)
	require.Nil(t, signed.GetException())
	require.Equal(t, "zoho-invoice", signed.GetClaim().GetStep())

	require.Equal(t, "payment-approved", answerConnectors(t, server, id))
	approved, err := server.PaymentApproved(ctx, &pb.PaymentApprovedRequest{ClaimId: id, SignedBy: "payments@example.com"})
	require.NoError(t, err)
	require.Equal(t, "payment-status", approved.GetClaim().GetStep())

	// ABS may report pending first; the claim waits for the next status.
	pending, err := server.PaymentStatus(ctx, &pb.PaymentStatusRequest{ClaimId: id, PaymentId: "PAY-1", Status: "pending"})
	require.NoError(t, err)
	require.Equal(t, "payment-status", pending.GetClaim().GetStep())
	paid, err := server.PaymentStatus(ctx, &pb.PaymentStatusRequest{ClaimId: id, PaymentId: "PAY-1", Status: "Approved"})
	require.NoError(t, err)
	require.Equal(t, "d365fo-journal", paid.GetClaim().GetStep())

	answerConnectors(t, server, id)
	got, err := server.GetClaim(ctx, &pb.GetClaimRequest{ClaimId: id})
	require.NoError(t, err)
	claim := got.GetClaim()
	require.Equal(t, "done", claim.GetState())
	result := claim.GetResult().GetFields()
	require.Equal(t, "paid", result["decision"].GetStringValue())
	require.Equal(t, "jack.clarke@example.com", result["contract_signed_by"].GetStringValue())
	require.Equal(t, "PAY-1", result["payment_id"].GetStringValue())
	require.Equal(t, "SAP-TXN-1001", result["sap_txn"].GetStringValue())

	// A resend of the contract-signed webhook after the claim moved on is
	// refused with the reason, not applied again, with or without its key.
	for _, key := range []string{"sig-1", ""} {
		late, err := server.ContractSigned(ctx, &pb.ContractSignedRequest{ClaimId: id, SignedBy: "jack.clarke@example.com", RequestKey: key})
		require.NoError(t, err)
		require.Equal(t, `claim `+id+` is done at "", not waiting for contract-signed`, late.GetException().GetDescription())
	}
}

func TestUnknownClaimIsABusinessError(t *testing.T) {
	server := makeTestServer(t)
	ctx := context.Background()
	got, err := server.GetClaim(ctx, &pb.GetClaimRequest{ClaimId: "no-such-claim"})
	require.NoError(t, err)
	require.Equal(t, "claim no-such-claim not found", got.GetException().GetDescription())
	signed, err := server.ContractSigned(ctx, &pb.ContractSignedRequest{ClaimId: "no-such-claim", SignedBy: "x@example.com"})
	require.NoError(t, err)
	require.Equal(t, "claim no-such-claim not found", signed.GetException().GetDescription())
}

func TestStartRejectedByThePhylumIsABusinessError(t *testing.T) {
	server := makeTestServer(t)
	req := testStartRequest()
	req.InvoiceAmount = "lots"
	resp, err := server.StartClaim(context.Background(), req)
	require.NoError(t, err)
	require.Equal(t, "invoice_amount lots is not a positive number", resp.GetException().GetDescription())
}

// TestStartRequiredFieldsMatchPhylum keeps the portal's list of required
// start fields in step with the phylum's.  The portal checks them first so
// a caller sees every missing field at once, before a transaction runs.
func TestStartRequiredFieldsMatchPhylum(t *testing.T) {
	src, err := os.ReadFile(filepath.Join(phylumRelPath, "claim-steps.lisp"))
	require.NoError(t, err)
	m := regexp.MustCompile(`\(set 'claim-required-fields\s*\(vector ([^)]*)\)\)`).FindSubmatch(src)
	require.NotNil(t, m, "claim-required-fields not found in claim-steps.lisp")
	var phylum []string
	for _, f := range regexp.MustCompile(`"([^"]+)"`).FindAllSubmatch(m[1], -1) {
		phylum = append(phylum, string(f[1]))
	}
	require.Equal(t, phylum, startRequiredFields)
}
