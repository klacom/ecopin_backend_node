# Verification secret logging repair

Verification URLs and token prefixes were printed during email preparation and registration. The combined request logger also recorded token-bearing URLs and referrers. Database and SMTP error objects could echo a token back into logs.

The request logger now redacts sensitive query values, including repeated or encoded token keys, while preserving ordinary filters, HTTP method, status and response size. URL userinfo and fragments are excluded. Service success logs omit links and token prefixes; database/SMTP failures expose only a bounded error code and propagate generic messages. Verification links remain in the intended email body. No authentication or redemption behavior changes in this repair.

Four behavioral tests reproduced service success/error leaks before the fix. Nine URL/middleware tests cover redaction and a real local HTTP request. All 147 backend tests passed. Email delivery and registration are mocked in these tests; no email was sent and no real account created.

The fresh PostGIS report privacy recovery drill also passed: 111 assertions, exact report policy/ACL restoration on rollback, then 28 privacy assertions after reapplication. This is a synthetic schema recovery drill, not a complete Auth/media/platform restoration.

S02 remains incomplete: tokens are still stored as UUID plaintext, redemption has separate unchecked updates, and token retention and dedicated auth throttling need verification/repair. All eight current token rows were expired; none was unused and unexpired at inspection. This does not make the next generated token safe without the remaining work.

Morgan uses a documented custom formatting function: [Express Morgan documentation](https://expressjs.com/en/resources/middleware/morgan/).
