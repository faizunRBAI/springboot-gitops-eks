# ---------------------------------------------------------------------------
# VPC across 3 availability zones.
#
# Public subnets  : ALB + the single NAT gateway.
# Private subnets : EKS worker nodes (no public IPs; egress via NAT).
#
# SINGLE NAT GATEWAY (deliberate): the probe measured an Elastic IP quota of 5
# in this account. One NAT per AZ would consume 3 EIPs and roughly $97/month;
# one shared NAT costs about $32/month and leaves EIP headroom.
# Trade-off: if the NAT's AZ fails, private-subnet egress stops until it is
# recreated. Nodes and the control plane remain spread across 3 AZs.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az_count = 3
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # 10.0.0.0/16 -> /20 slices: public 10.0.0-2.x, private 10.0.16-48.x
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + local.az_count)]
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both required by EKS: nodes resolve the cluster endpoint and each other
  # through VPC-provided DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${local.azs[count.index]}"
    # Tells the AWS Load Balancer Controller it may place INTERNET-FACING
    # load balancers here. Without this tag, ingress creation fails with
    # "could not find any suitable subnets for creating the ALB".
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-private-${local.azs[count.index]}"
    # Marks these subnets as candidates for INTERNAL load balancers.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- Single NAT gateway -----------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- Routing ----------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# All three private subnets share one route table pointing at the single NAT.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
