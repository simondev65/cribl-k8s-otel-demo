variable "worker_group_name" {
  description = "Name of the Stream Worker Group"
  default = "otel-demo-k8s-wg"
}

# Create a Stream Worker Group
resource "criblio_group" "k8s_stream_worker_group" {
  id                    = var.worker_group_name
  is_fleet              = false
  name                  = var.worker_group_name
  product               = "stream"
  provisioned           = false
  on_prem               = true
  worker_remote_access = true

}

# Create Cribl Lake dataset for OTel traces
resource "criblio_destination" "otel_traces_lake_dataset" {
    id       = "otel-traces"
    group_id = criblio_group.k8s_stream_worker_group.id

    output_cribl_lake = {
        id          = "otel-traces"
        type        = "cribl_lake"
        dest_path   = criblio_cribl_lake_dataset.otel_traces.id
    }

  lifecycle {
    create_before_destroy = true
  }

}

# Create Cribl Lake dataset for OTel metrics
resource "criblio_destination" "otel_metrics_lake_dataset" {
    id       = "otel-metrics"
    group_id = criblio_group.k8s_stream_worker_group.id  

    output_cribl_lake = {
        id          = "otel-metrics"
        type        = "cribl_lake"
        dest_path   = criblio_cribl_lake_dataset.otel_metrics.id
    }

  lifecycle {
    create_before_destroy = true
  }

}

# Create Cribl Lake dataset for OTel logs
resource "criblio_destination" "otel_logs_lake_dataset" {
    id       = "otel-logs"
    group_id = criblio_group.k8s_stream_worker_group.id

    output_cribl_lake = {
        id          = "otel-logs"
        type        = "cribl_lake"
        dest_path   = criblio_cribl_lake_dataset.otel_logs.id
    }
  lifecycle {
    create_before_destroy = true
  }
  
}

# Create a Router destination to route OTel data to appropriate Lake datasets
resource "criblio_destination" "otel_data_router" {
    id       = "otel-data-router"
    group_id = criblio_group.k8s_stream_worker_group.id

    output_router = {
      id =      "otel-data-router"
      type =    "router"
      rules = [ 
        {
            filter = "__otlp.type == 'traces'"
            output = "otel-traces"
            description = "OTel traces to Lake"
            final = true
        },
        {
            filter = "__otlp.type == 'metrics'"
            output = "otel-metrics"
            description = "OTel metrics to Lake"
            final = true
        },
        {
            filter = "__otlp.type == 'logs'"
            output = "otel-logs"
            description = "OTel logs to Lake"
            final = true
        }
      ]
    }

  lifecycle {
    create_before_destroy = true
  }

    depends_on = [ criblio_destination.otel_traces_lake_dataset, criblio_destination.otel_metrics_lake_dataset, criblio_destination.otel_logs_lake_dataset ]

}

# Create Prometheus destination
resource "criblio_destination" "elastic-prometheus" {
    id          = "elastic-prometheus"
    group_id    = criblio_group.k8s_stream_worker_group.id

    output_prometheus = {
      id        = "elastic-prometheus"
      type      = "prometheus"
      url       = "http://prometheus.elastic.svc.cluster.local:9201"
      auth_type = "none"
    }

  lifecycle {
    create_before_destroy = true
  }
}

# Create OTel destination
resource "criblio_destination" "elastic-otel" {
    id          = "elastic-otel"
    group_id    = criblio_group.k8s_stream_worker_group.id

    output_open_telemetry = {
      id                = "elastic-otel"
      type              = "open_telemetry"
      protocol          = "grpc"
      version           = "1.3.1"
      otlp_version      = "1.3.1"
      auth_type         = "none" 
      endpoint          = "apm.elastic.svc.cluster.local:8200"
      tls = {
        disabled = true
      }
    }

  lifecycle {
    create_before_destroy = true
  }
}

# Create a Cribl HTTP source routed to Elastic OTel
resource "criblio_source" "in_k8s_cribl_http" {
    id       = "in_k8s_cribl_http"
    group_id = criblio_group.k8s_stream_worker_group.id

        input_cribl_http = {
        id              = "in_k8s_cribl_http"
        type            = "cribl_http"
        port            = 10200
        send_to_routes  = false
        tls             = {
            disabled = true
        }
        connections = [ 
            {
                output = "elastic-otel"
            }
        ]
        disabled        = false
    }

    depends_on = [ criblio_destination.elastic-otel ]

}

# Create a Cribl TCP source sending data to routes
resource "criblio_source" "in_k8s_cribl_tcp" {
    id       = "in_k8s_cribl_tcp"
    group_id = criblio_group.k8s_stream_worker_group.id

    input_cribl_tcp = {
        id              = "in_k8s_cribl_tcp"
        type            = "cribl_tcp"
        port            = 10300
        send_to_routes  = true
        disabled        = false
    }
}

# Install cribl-opentelemetry pack
resource "criblio_pack" "cribl_opentelemetry_pack" {
    id              = "cribl-opentelemetry-pack"
    group_id        = criblio_group.k8s_stream_worker_group.id
    display_name    = "OTel pack"
    filename        = "${abspath(path.module)}/cribl-opentelemetry-pack_0-1-1.crbl"
    version         = "0.1.1"
    description     = "OpenTelemetry to metrics"
}

# Create metrics-to-elastic pipeline from inline JSON
resource "criblio_pipeline" "metrics_to_elastic_pipeline" {
    id       = "metrics_to_elastic_pipeline"
    group_id = criblio_group.k8s_stream_worker_group.id
    
    conf = {
        output = "default"
        groups = {}
        async_func_timeout = 1000
        functions = [ 
            {
               id = "comment"
               filter = "true"
               conf = jsonencode({
                    comment = "Invoke the OTel to metrics pack"
               }) 
            },
            {
                id = "chain"
                filter = "true"
                conf = jsonencode({
                    processor = "pack:cribl-opentelemetry-pack"
                })
                description = "Invoke the Cribl OpenTelemetry pack"
            },            
            {
               id = "comment"
               filter = "true"
               conf =jsonencode({
                    comment = "Reduce the granularity of metrics by aggregating them"
               }) 
            },
            {
                id = "aggregation"
                filter = "true"
                conf = jsonencode({
                    passthrough = false
                    preserveGroupBys = false
                    sufficientStatsOnly = false
                    metricsMode = true
                    timeWindow = "60s"
                    cumulative = false
                    flushOnInputClose = true                    
                    aggregations = [
                        "sum(duration).as(duration)",
                        "sum(http_2xx).as(http_2xx)",
                        "sum(http_3xx).as(http_3xx)",
                        "sum(http_4xx).as(http_4xx)",
                        "sum(http_5xx).as(http_5xx)",
                        "sum(otel_status_0).as(otel_status_0)",
                        "sum(otel_status_1).as(otel_status_1)",
                        "sum(otel_status_2).as(otel_status_2)",
                        "sum(requests_error).as(requests_error)",
                        "sum(requests_total).as(requests_total)",
                        "max(start_time_unix_nano).as(max_starttime)"
                    ]
                    groupbys = [
                        "service",
                        "resource_url",
                        "status_code"
                    ]
                })
                description = "Aggregate metrics before sending them"
            },
            {
               id = "comment"
               filter = "true"
               conf = jsonencode({
                    comment = "Fix the timestamp to max_time of the aggregated spans"
               }) 
            },
            {
                id = "auto_timestamp"
                filter = "true"
                conf = jsonencode({
                    srcField = "max_starttime"
                    dstField = "_time"
                    defaultTimezone = "UTC"
                    timeExpression = "time.getTime() / 1000"
                    offset = 0
                    maxLen = 150
                    defaultTime = "now"
                    latestDateAllowed = "+1week"
                    earliestDateAllowed = "-420weeks"
                })
            }
        ]
    }

}

# Create routing table
resource "criblio_routes" "routing_table" {

    group_id = criblio_group.k8s_stream_worker_group.id
    routes = [
        {
            name = "Send logs, metrics and traces to Lake"
            final = false
            disabled = false
            pipeline = "passthru"
            description = "Send logs, metrics and traces to Lake"
            filter = "__otlp.type"
            output = jsonencode("otel-data-router")
        },
        {
            name = "Create RED metrics from OTel traces"
            final = false
            disabled = false
            pipeline = criblio_pipeline.metrics_to_elastic_pipeline.id
            description = "Send logs, metrics and traces to Lake"
            filter = "__otlp.type"
            output = jsonencode("elastic-prometheus")
        },          
        {
            name = "Send everything to Elastic"
            final = true
            disabled = true
            pipeline = "passthru"
            description = "Send everything to Elastic"
            filter = "__otlp.type"
            output = jsonencode("elastic-otel")
        },           
        {
            name = "Default"
            final = true
            disabled = false
            pipeline = "devnull"
            description = ""
            filter = "true"
            output = jsonencode("devnull")
        }
    ]


    depends_on = [ criblio_destination.elastic-otel, criblio_destination.otel_data_router, criblio_destination.elastic-prometheus ]

}


# Commit and deploy the configuration
data "criblio_config_version" "stream_configversion" {
  id         = criblio_group.k8s_stream_worker_group.id
  depends_on = [ criblio_commit.stream_commit ]
}

resource "criblio_commit" "stream_commit" {
  effective = true
  group     = criblio_group.k8s_stream_worker_group.id
  message   = "Automated Stream configuration commit"

  depends_on = [ criblio_routes.routing_table ]
}

resource "criblio_deploy" "stream_deploy" {
  id      = criblio_group.k8s_stream_worker_group.id
  version = data.criblio_config_version.stream_configversion.items[0]

  depends_on = [ criblio_commit.stream_commit ]
}