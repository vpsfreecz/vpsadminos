package reposerver

// Frozen v1 scalar expressions are persisted in schema 3's expression index.
// Never change these definitions after consumption: a changed metric needs a new
// expression version and migration. Keep queries and index DDL on the same ASTs.
const (
	usageFullDownloadsV1       = `CASE WHEN method='GET' AND status=200 AND outcome='complete' THEN requests ELSE 0 END`
	usageRangeRequestsV1       = `CASE WHEN method='GET' AND status=206 THEN requests ELSE 0 END`
	usageTransferredBytesV1    = `CASE WHEN method='GET' AND status IN (200,206) THEN bytes ELSE 0 END`
	usageInterruptedRequestsV1 = `CASE WHEN outcome='interrupted' THEN requests ELSE 0 END`
	usageErrorRequestsV1       = `CASE WHEN status>=400 THEN requests ELSE 0 END`
)

const usageSums = `coalesce(sum(` + usageFullDownloadsV1 + `),0),coalesce(sum(` + usageRangeRequestsV1 + `),0),coalesce(sum(` + usageTransferredBytesV1 + `),0),coalesce(sum(` + usageInterruptedRequestsV1 + `),0),coalesce(sum(` + usageErrorRequestsV1 + `),0)`

const usageIndexV3 = `CREATE INDEX http_daily_usage_expr ON http_daily(repository,instance,scope,kind,day,distribution,arch,vendor,variant,version,` + usageFullDownloadsV1 + `,` + usageRangeRequestsV1 + `,` + usageTransferredBytesV1 + `,` + usageInterruptedRequestsV1 + `,` + usageErrorRequestsV1 + `)`
