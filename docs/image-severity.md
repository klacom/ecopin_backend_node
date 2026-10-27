# Image severity

Local and Lambda inference share `image_validation/severity_estimator.py`. Both
return scale (`small`, `medium`, `large`) and obstruction (`none`, `partial`,
`complete`), their relative CLIP confidence scores, and per-label scores for
approved and review-zone images. Rejected images return null severity features.
The trained validity classifier and its decision thresholds are unchanged.

The backend uses the confidence-weighted image votes in both report creation and
media synchronization. Missing predictions retain the existing defaults.

Severity weights are scale 35%, hazard 20%, obstruction 30%, persistence 5%, and
location sensitivity 10%. This prioritizes visible impact while keeping all five
factors. First-report public-space waste scores are 26 for small/unobstructed,
52 for medium/partially obstructing, and 79 for large/fully obstructing. The last
case reaches both the High display level and the lifecycle high tier (67+).

Scale prompts now compare scattered litter, a localized pile, and a large pile
covering a substantial part of a public area. These are zero-shot estimates;
prompt changes are not evidence of validated accuracy. Evaluate a labeled set of
small, medium, and large scenes before claiming accuracy or calibrated confidence.

Deploy the backend and rebuild the image-validation Lambda container together;
the Docker build includes the shared estimator. Restart local inference processes
to load the new prompts. Existing stored scores are not automatically recomputed.
