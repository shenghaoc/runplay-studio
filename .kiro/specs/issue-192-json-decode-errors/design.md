# Design

Translate Foundation decoding errors at the JSON decoder boundary. The two single-file import paths scope their persistence message to the library actor's add call and reuse the existing import messages for failures before that call. The same library transaction continues to save the workout and manifest; the caller reports the result without changing transaction order.
