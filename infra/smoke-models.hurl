# Calls every LiteLLM alias of one stack with the server's keys. Run it
# through infra/smoke-models.sh, which port-forwards LiteLLM and reads the keys.

# search: the model reads a query.
POST {{litellm}}/v1/chat/completions
Authorization: Bearer {{llm_key}}
{"model": "search", "messages": [{"role": "user", "content": "Reply with the word ok."}], "max_tokens": 5}
HTTP 200

# stt: a silent clip gives empty text.
POST {{litellm}}/v1/audio/transcriptions
Authorization: Bearer {{stt_key}}
[MultipartFormData]
model: stt
file: file,silence.wav; audio/wav
HTTP 200
[Asserts]
jsonpath "$.text" == ""

# embed-text with the search key: bge-m3, 1024 dimensions.
POST {{litellm}}/v1/embeddings
Authorization: Bearer {{embed_search_key}}
{"model": "embed-text", "input": ["xe đạp trẻ em"]}
HTTP 200
[Asserts]
jsonpath "$.data[0].embedding" count == 1024

# embed-image with the search key, a photo: SigLIP 2, 1152 dimensions.
POST {{litellm}}/v1/embeddings
Authorization: Bearer {{embed_search_key}}
{"model": "embed-image", "input": ["{{photo}}"]}
HTTP 200
[Asserts]
jsonpath "$.data[0].embedding" count == 1152

# embed-image with the index key, a text for the text tower.
POST {{litellm}}/v1/embeddings
Authorization: Bearer {{embed_index_key}}
{"model": "embed-image", "input": ["a blue bicycle"]}
HTTP 200
[Asserts]
jsonpath "$.data[0].embedding" count == 1152

# A key reaches only its own aliases.
POST {{litellm}}/v1/embeddings
Authorization: Bearer {{llm_key}}
{"model": "embed-text", "input": ["x"]}
HTTP 403
