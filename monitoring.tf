data "aws_region" "monitoring" {
  count = local.create_vpc && (var.enable_cloudwatch_dashboard || var.enable_nat_gateway_alarms) ? 1 : 0

  region = var.region
}

locals {
  monitoring_region = try(data.aws_region.monitoring[0].name, var.region, "")
  dashboard_name    = coalesce(var.cloudwatch_dashboard_name, "${var.name}-vpc-overview")

  # NAT Gateway IDs
  nat_gateway_ids = local.create_vpc && var.enable_nat_gateway ? aws_nat_gateway.this[*].id : []

  # NAT Gateway metrics for CloudWatch Dashboard
  natgw_bytes_metrics = flatten([
    for id in local.nat_gateway_ids : [
      ["AWS/NATGateway", "BytesInFromDestination", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Bytes In from Dest" }],
      ["AWS/NATGateway", "BytesInFromSource", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Bytes In from Source" }],
      ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Bytes Out to Dest" }],
      ["AWS/NATGateway", "BytesOutToSource", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Bytes Out to Source" }]
    ]
  ])

  natgw_conn_metrics = flatten([
    for id in local.nat_gateway_ids : [
      ["AWS/NATGateway", "ActiveConnectionCount", "NatGatewayId", id, { stat = "Average", period = 300, label = "${id} - Active Connections" }],
      ["AWS/NATGateway", "ConnectionEstablishedCount", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Connections Established" }],
      ["AWS/NATGateway", "ConnectionAttemptCount", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Connection Attempts" }]
    ]
  ])

  natgw_error_metrics = flatten([
    for id in local.nat_gateway_ids : [
      ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", id, { stat = "Sum", period = 300, color = "#d62728", label = "${id} - Error Port Allocation" }],
      ["AWS/NATGateway", "PacketsDropCount", "NatGatewayId", id, { stat = "Sum", period = 300, color = "#ff7f0e", label = "${id} - Packets Dropped" }]
    ]
  ])

  natgw_packets_metrics = flatten([
    for id in local.nat_gateway_ids : [
      ["AWS/NATGateway", "PacketsInFromDestination", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Packets In from Dest" }],
      ["AWS/NATGateway", "PacketsOutToDestination", "NatGatewayId", id, { stat = "Sum", period = 300, label = "${id} - Packets Out to Dest" }]
    ]
  ])

  has_flow_log_group  = local.create_flow_log_cloudwatch_log_group && length(aws_cloudwatch_log_group.flow_log) > 0
  flow_log_group_name = local.has_flow_log_group ? aws_cloudwatch_log_group.flow_log[0].name : ""

  # Widgets list constructed cleanly
  dashboard_widgets = concat(
    [
      # Header banner widget
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "## VPC Operations Overview: **${var.name}**\n**VPC ID:** `${local.vpc_id}` | **IPv4 CIDR:** `${var.cidr}` | **Region:** `${local.monitoring_region}` | **NAT Gateways:** ${length(local.nat_gateway_ids)} | **Subnets:** ${length(var.public_subnets)} public / ${length(var.private_subnets)} private"
        }
      },
      # Network Address Usage (NAU) widget
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "VPC Network Address Usage (NAU)"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = [
            ["AWS/EC2", "NetworkAddressUsage", "Vpc", local.vpc_id, { stat = "Maximum", period = 300, label = "Network Address Usage (IPs)" }],
            ["AWS/EC2", "NetworkAddressUsagePeering", "Vpc", local.vpc_id, { stat = "Maximum", period = 300, label = "NAU Peering" }]
          ]
          yAxis = {
            left = { min = 0 }
          }
        }
      },
      # Flow Logs widget or Subnet Architecture widget
      local.has_flow_log_group ? {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "VPC Flow Logs - Ingestion Volume & Event Count"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = [
            ["AWS/Logs", "IncomingBytes", "LogGroupName", local.flow_log_group_name, { stat = "Sum", period = 300, yAxis = "left", label = "Bytes Ingested" }],
            ["AWS/Logs", "IncomingLogEvents", "LogGroupName", local.flow_log_group_name, { stat = "Sum", period = 300, yAxis = "right", label = "Log Events Count" }]
          ]
        }
        } : {
        type   = "text"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          markdown = "### Subnet Topology & Routing\n- **Public Subnets:** ${length(var.public_subnets)}\n- **Private Subnets:** ${length(var.private_subnets)}\n- **Database Subnets:** ${length(var.database_subnets)}\n- **Intra Subnets:** ${length(var.intra_subnets)}\n- **Flow Logs Enabled:** ${local.enable_flow_log}\n- **VPN Gateway:** ${var.enable_vpn_gateway}\n- **DNS Hostnames:** ${var.enable_dns_hostnames}\n- **DNS Support:** ${var.enable_dns_support}"
        }
      }
    ],
    # NAT Gateway Traffic and Connection widgets (if NAT Gateways exist)
    length(local.nat_gateway_ids) > 0 ? [
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "NAT Gateway Traffic (Bytes In / Bytes Out)"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = local.natgw_bytes_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "NAT Gateway Connections (Active & Attempts)"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = local.natgw_conn_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "NAT Gateway Health (Errors & Drops)"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = local.natgw_error_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "NAT Gateway Packets (In / Out)"
          view    = "timeSeries"
          stacked = false
          region  = local.monitoring_region
          metrics = local.natgw_packets_metrics
        }
      }
    ] : []
  )
}

################################################################################
# CloudWatch Dashboard
################################################################################

resource "aws_cloudwatch_dashboard" "this" {
  count = local.create_vpc && var.enable_cloudwatch_dashboard ? 1 : 0

  dashboard_name = local.dashboard_name
  dashboard_body = jsonencode({
    widgets = local.dashboard_widgets
  })
}

################################################################################
# CloudWatch Alarms - NAT Gateway
################################################################################

resource "aws_cloudwatch_metric_alarm" "nat_gateway_error_port_allocation" {
  count = local.create_vpc && var.enable_nat_gateway && var.enable_nat_gateway_alarms ? local.nat_gateway_count : 0

  alarm_name          = "${var.name}-natgw-${element(var.azs, var.single_nat_gateway ? 0 : count.index)}-port-allocation-error"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.nat_gateway_alarm_evaluation_periods
  metric_name         = "ErrorPortAllocation"
  namespace           = "AWS/NATGateway"
  period              = var.nat_gateway_alarm_period
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "NAT Gateway ${element(aws_nat_gateway.this[*].id, count.index)} has encountered port allocation errors (out of available source ports for SNAT)."

  alarm_actions = var.nat_gateway_alarm_actions
  ok_actions    = var.nat_gateway_alarm_ok_actions

  dimensions = {
    NatGatewayId = element(aws_nat_gateway.this[*].id, count.index)
  }

  tags = merge(
    {
      "Name" = "${var.name}-natgw-${element(var.azs, var.single_nat_gateway ? 0 : count.index)}-port-allocation-error"
    },
    var.tags,
  )
}

resource "aws_cloudwatch_metric_alarm" "nat_gateway_packets_drop" {
  count = local.create_vpc && var.enable_nat_gateway && var.enable_nat_gateway_alarms ? local.nat_gateway_count : 0

  alarm_name          = "${var.name}-natgw-${element(var.azs, var.single_nat_gateway ? 0 : count.index)}-packet-drops"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.nat_gateway_alarm_evaluation_periods
  metric_name         = "PacketsDropCount"
  namespace           = "AWS/NATGateway"
  period              = var.nat_gateway_alarm_period
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "NAT Gateway ${element(aws_nat_gateway.this[*].id, count.index)} is dropping packets."

  alarm_actions = var.nat_gateway_alarm_actions
  ok_actions    = var.nat_gateway_alarm_ok_actions

  dimensions = {
    NatGatewayId = element(aws_nat_gateway.this[*].id, count.index)
  }

  tags = merge(
    {
      "Name" = "${var.name}-natgw-${element(var.azs, var.single_nat_gateway ? 0 : count.index)}-packet-drops"
    },
    var.tags,
  )
}
