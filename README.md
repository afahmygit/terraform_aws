# AWS VPC Terraform module

Terraform module which creates VPC resources on AWS.

## Usage

```hcl
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}
```

## External NAT Gateway IPs

By default this module will provision new Elastic IPs for the VPC's NAT Gateways.
This means that when creating a new VPC, new IPs are allocated, and when that VPC is destroyed those IPs are released.
Sometimes it is handy to keep the same IPs even after the VPC is destroyed and re-created.
To that end, it is possible to assign existing IPs to the NAT Gateways.
This prevents the destruction of the VPC from releasing those IPs, while making it possible that a re-created VPC uses the same IPs.

To achieve this, allocate the IPs outside the VPC module declaration.

```hcl
resource "aws_eip" "nat" {
  count = 3

  vpc = true
}
```

Then, pass the allocated IPs as a parameter to this module.

```hcl
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  # The rest of arguments are omitted for brevity

  enable_nat_gateway  = true
  single_nat_gateway  = false
  reuse_nat_ips       = true                    # <= Skip creation of EIPs for the NAT Gateways
  external_nat_ip_ids = "${aws_eip.nat.*.id}"   # <= IPs specified here as input to the module
}
```

Note that in the example we allocate 3 IPs because we will be provisioning 3 NAT Gateways (due to `single_nat_gateway = false` and having 3 subnets).
If, on the other hand, `single_nat_gateway = true`, then `aws_eip.nat` would only need to allocate 1 IP.
Passing the IPs into the module is done by setting two variables `reuse_nat_ips = true` and `external_nat_ip_ids = "${aws_eip.nat.*.id}"`.

## NAT Gateway Scenarios

This module supports three scenarios for creating NAT gateways. Each will be explained in further detail in the corresponding sections.

- One NAT Gateway per subnet (default behavior)
  - `enable_nat_gateway = true`
  - `single_nat_gateway = false`
  - `one_nat_gateway_per_az = false`
- Single NAT Gateway
  - `enable_nat_gateway = true`
  - `single_nat_gateway = true`
  - `one_nat_gateway_per_az = false`
- One NAT Gateway per availability zone
  - `enable_nat_gateway = true`
  - `single_nat_gateway = false`
  - `one_nat_gateway_per_az = true`

If both `single_nat_gateway` and `one_nat_gateway_per_az` are set to `true`, then `single_nat_gateway` takes precedence.

### One NAT Gateway per subnet (default)

By default, the module will determine the number of NAT Gateways to create based on the the `max()` of the private subnet lists (`database_subnets`, `elasticache_subnets`, `private_subnets`, and `redshift_subnets`). The module **does not** take into account the number of `intra_subnets`, since the latter are designed to have no Internet access via NAT Gateway. For example, if your configuration looks like the following:

```hcl
database_subnets    = ["10.0.21.0/24", "10.0.22.0/24"]
elasticache_subnets = ["10.0.31.0/24", "10.0.32.0/24"]
private_subnets     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24", "10.0.5.0/24"]
redshift_subnets    = ["10.0.41.0/24", "10.0.42.0/24"]
intra_subnets       = ["10.0.51.0/24", "10.0.52.0/24", "10.0.53.0/24"]
```

Then `5` NAT Gateways will be created since `5` private subnet CIDR blocks were specified.

### Single NAT Gateway

If `single_nat_gateway = true`, then all private subnets will route their Internet traffic through this single NAT gateway. The NAT gateway will be placed in the first public subnet in your `public_subnets` block.

### One NAT Gateway per availability zone

If `one_nat_gateway_per_az = true` and `single_nat_gateway = false`, then the module will place one NAT gateway in each availability zone you specify in `var.azs`. There are some requirements around using this feature flag:

- The variable `var.azs` **must** be specified.
- The number of public subnet CIDR blocks specified in `public_subnets` **must** be greater than or equal to the number of availability zones specified in `var.azs`. This is to ensure that each NAT Gateway has a dedicated public subnet to deploy to.

## "private" versus "intra" subnets

By default, if NAT Gateways are enabled, private subnets will be configured with routes for Internet traffic that point at the NAT Gateways configured by use of the above options.

If you need private subnets that should have no Internet routing (in the sense of [RFC1918 Category 1 subnets](https://tools.ietf.org/html/rfc1918)), `intra_subnets` should be specified. An example use case is configuration of AWS Lambda functions within a VPC, where AWS Lambda functions only need to pass traffic to internal resources or VPC endpoints for AWS services.

Since AWS Lambda functions allocate Elastic Network Interfaces in proportion to the traffic received ([read more](https://docs.aws.amazon.com/lambda/latest/dg/vpc.html)), it can be useful to allocate a large private subnet for such allocations, while keeping the traffic they generate entirely internal to the VPC.

You can add additional tags with `intra_subnet_tags` as with other subnet types.

## VPC Flow Log

VPC Flow Log allows to capture IP traffic for a specific network interface (ENI), subnet, or entire VPC. This module supports enabling or disabling VPC Flow Logs for entire VPC. If you need to have VPC Flow Logs for subnet or ENI, you have to manage it outside of this module with [aws_flow_log resource](https://www.terraform.io/docs/providers/aws/r/flow_log.html).

### VPC Flow Log Examples

By default `file_format` is `plain-text`. You can also specify `parquet` to have logs written in Apache Parquet format.

```
flow_log_file_format = "parquet"
```

### Permissions Boundary

If your organization requires a permissions boundary to be attached to the VPC Flow Log role, make sure that you specify an ARN of the permissions boundary policy as `vpc_flow_log_permissions_boundary` argument. Read more about required [IAM policy for publishing flow logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-cwl.html#flow-logs-iam).

## Conditional creation

Prior to Terraform 0.13, you were unable to specify `count` in a module block. If you wish to toggle the creation of the module's resources in an older (pre 0.13) version of Terraform, you can use the `create_vpc` argument.

```hcl
# This VPC will not be created
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  create_vpc = false
  # ... omitted
}
```

## Public access to RDS instances

Sometimes it is handy to have public access to RDS instances (it is not recommended for production) by specifying these arguments:

```hcl
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true

  enable_dns_hostnames = true
  enable_dns_support   = true
```

## Network Access Control Lists (ACL or NACL)

This module can manage network ACL and rules. Once VPC is created, AWS creates the default network ACL, which can be controlled using this module (`manage_default_network_acl = true`).

Also, each type of subnet may have its own network ACL with custom rules per subnet. Eg, set `public_dedicated_network_acl = true` to use dedicated network ACL for the public subnets; set values of `public_inbound_acl_rules` and `public_outbound_acl_rules` to specify all the NACL rules you need to have on public subnets (see `variables.tf` for default values and structures).

By default, all subnets are associated with the default network ACL.

## Public access to Redshift cluster

Sometimes it is handy to have public access to Redshift clusters (for example if you need to access it by Kinesis - VPC endpoint for Kinesis is not yet supported by Redshift) by specifying these arguments:

```hcl
  enable_public_redshift = true  # <= By default Redshift subnets will be associated with the private route table
```

## Transit Gateway (TGW) integration

It is possible to integrate this VPC module with [terraform-aws-transit-gateway module](https://github.com/terraform-aws-modules/terraform-aws-transit-gateway) which handles the creation of TGW resources and VPC attachments. See [complete example there](https://github.com/terraform-aws-modules/terraform-aws-transit-gateway/tree/master/examples/complete).

## Examples

- [Simple VPC](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/simple-vpc)
- [Simple VPC with secondary CIDR blocks](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/secondary-cidr-blocks)
- [Complete VPC](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/complete-vpc) with VPC Endpoints.
- [VPC with IPv6 enabled](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/ipv6)
- [Network ACL](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/network-acls)
- [VPC Flow Logs](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/vpc-flow-logs)
- [VPC with Outpost](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/outpost)
- [Manage Default VPC](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/manage-default-vpc)
- [Few tests and edge case examples](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master/examples/issues)

