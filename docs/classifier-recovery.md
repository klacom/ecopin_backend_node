# Image classifier outage recovery

Report creation returns 201 after storing the report; media synchronization returns 202. Evidence upload occurs before classification. A classifier outage must not turn submitted evidence into a rejection or erase citizen scale/obstruction.

Both image paths now require a response for every classification image before applying the existing majority decision. Any failed call routes the report to manual review, including a mixture of a rejection and a timeout. Complete, conclusive responses retain their existing approval/rejection behavior. There is no automatic approval during an outage.

The classifier client's 30-second deadline remains active until the response body has been consumed, so a response with stalled JSON cannot leave validation pending indefinitely. No automatic request retries are added: citizens can retry the photo check or explicitly request manual review in the existing app flow.

Regression tests exercise both controllers with mocked classifier transport and storage: complete outage, partial approval, partial rejection, conclusive approval/rejection, preserved uploads/citizen factors, and a stalled response body. Run `npm test -- --runInBand`.

## Observed production timing, November 2, 2026

- API Gateway HTTP integration `f7prj6n`: 30,000ms timeout.
- Backend classifier request: 30,000ms; health check: 5,000ms.
- Lambda function timeout: 120 seconds; memory: 3,008MB.
- CloudWatch recorded initial requests of 40,707.94ms, 55,854.72ms and 78,979.60ms during initialization. These are observed request durations around cold starts, not isolated model-loading benchmarks or population percentiles.
- Warm real-image requests measured 193.43–214.61ms in Lambda reports.

HTTP API's [30-second integration limit](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-quotas.html) cannot be increased. [Lambda initialization](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtime-environment.html) may be retried during the first invocation after the initial 10-second initialization budget expires. A longer backend timeout alone therefore cannot resolve this path's cold starts.

Keep manual review as the fallback. Reducing model startup time is a separate measured optimization; an asynchronous inference worker is a larger architectural option if immediate automated validation is required. No paid provisioned concurrency, keep-warm schedule, gateway changes or new infrastructure are introduced by this fix.

Scope: no model changes, severity policy changes, migrations or historical report recomputation. This does not make the in-process background work durable across a backend process crash; durable queuing remains a separate reliability task. Storage failures are distinct from classifier outages.
