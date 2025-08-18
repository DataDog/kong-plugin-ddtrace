# Log Correlation using NGINX variables

This is a `docker compose` setup that showcases how to add `trace_id` and `span_id` to the nginx logs.

## How to run the example

1. Start the services using Docker compose with your Datadog API key:

```shell
DD_API_KEY=<KEY> docker compose up
```

2. Send a request to Kong to generate traffic and a trace

```shell
curl http://localhost:8000/foo
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "Traceparent": "00-c9a6361300000000269a8b8c076bafcb-55eb48277a5d69e1-01",
    "Tracestate": "dd=p:55eb48277a5d69e1;s:1;t.tid:c9a6361300000000;t.dm:-0",
    "User-Agent": "curl/8.6.0",
    "X-Amzn-Trace-Id": "Root=1-66587c78-12932e884e34a78e68008bc4",
    "X-Datadog-Parent-Id": "6191121447144745441",
    "X-Datadog-Sampling-Priority": "1",
    "X-Datadog-Tags": "_dd.p.tid=c9a6361300000000,_dd.p.dm=-0",
    "X-Datadog-Trace-Id": "2781689153390882763",
    "X-Forwarded-Host": "localhost",
    "X-Forwarded-Path": "/foo",
    "X-Forwarded-Prefix": "/foo"
  }
}
```

3. View the logs in the kong docker container. You'll see the trace_id (aa075....) and span_id (44ac...) at the end of the logs

```shell
kong-dbless-1  | 192.168.65.1 - - [14/Aug/2025:19:21:06 +0000] "GET /foo HTTP/1.1" 200 aa075e22000000008d2bf61b89079b85 44aca5af59df8fa0
```

The trace should be reported in your Datadog account. You may have to augment your Kong proxy log parsing rules to parse out the ids to attributes on the log for it to be properly linked to the trace
