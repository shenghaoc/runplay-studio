# Design

Doc-comment change only on `RouteGroupAssignmentPassResult`: the counts are computed totals and may exceed what was persisted under interleaved writes. The interleaving test stays; no committed-count API is added.
