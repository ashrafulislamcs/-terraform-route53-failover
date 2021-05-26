provider "aws" {
  region = var.region
}

data "aws_iam_role" "ecr" {
  name = "AWSServiceRoleForECRReplication"
}

module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=master"
  namespace  = "everlook"
  name       = "forge"
  attributes = ["public"]
  delimiter  = "-"
}

resource "aws_vpc" "main" {
  cidr_block = "10.10.0.0/16"

  tags = {
    Name = "main"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main"
  }
}

resource "aws_route_table" "gw" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table" "ngw" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gw.id
  }
}

resource "aws_nat_gateway" "gw" {
  allocation_id = aws_eip.nat1.id
  subnet_id     = aws_subnet.public_az1.id
}

resource "aws_route_table_association" "pub_a1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.gw.id
}

resource "aws_route_table_association" "pub_a2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.gw.id
}

resource "aws_route_table_association" "priv_a1" {
  subnet_id      = aws_subnet.private_az1.id
  route_table_id = aws_route_table.ngw.id
}

resource "aws_route_table_association" "priv_a2" {
  subnet_id      = aws_subnet.private_az2.id
  route_table_id = aws_route_table.ngw.id
}

resource "aws_eip" "nat2" {
  vpc = true

  depends_on = [aws_lb.alb]
}

resource "aws_eip" "nat1" {
  vpc = true

  depends_on = [aws_lb.alb]
}

resource "aws_subnet" "private_az1" {
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  cidr_block              = "10.10.10.0/24"
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "Private subnet for ${var.region}a"
  }
}

resource "aws_subnet" "private_az2" {
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
  cidr_block              = "10.10.20.0/24"
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "Private subnet for ${var.region}b"
  }
}

resource "aws_subnet" "public_az1" {
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  cidr_block              = "10.10.30.0/24"
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "Public subnet for ${var.region}a"
  }
}

resource "aws_subnet" "public_az2" {
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
  cidr_block              = "10.10.40.0/24"
  vpc_id                  = aws_vpc.main.id

  tags = {
    Name = "Public subnet for ${var.region}b"
  }
}


module "ecr" {
  source                 = "git::https://github.com/cloudposse/terraform-aws-ecr.git?ref=master"
  namespace              = module.label.namespace
  name                   = module.label.name
  principals_full_access = [data.aws_iam_role.ecr.arn]
}

data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
}

resource "aws_cloudwatch_log_group" "forge" {
  name = "forge"
}

resource "aws_ecs_task_definition" "node" {
  family                   = "forge"
  network_mode             = var.network_mode
  requires_compatibilities = [var.ecs_launch_type]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn

  container_definitions    = <<DEFINITION
[
  {
    "cpu": ${var.task_cpu},
    "environment": [{
      "name": "DEBUG",
      "value": "api*"
    }],
    "essential": true,
    "image": "${module.ecr.repository_url}:latest",
    "memory": ${var.task_memory},
    "name": "forge",
    "portMappings": [
      {
        "containerPort": 3000,
        "hostPort": 3000
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-region": "${var.region}",
        "awslogs-group": "${aws_cloudwatch_log_group.forge.id}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITION
}

resource "aws_ecs_cluster" "default" {
  name = module.label.id
}

resource "aws_security_group" "ecs_service" {
  name        = "ECS service sec group"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    # Load balancer forwards traffic to this port on our ecs service...
    # So we need to allow this ingress.
    description = "HTTP"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = -1
    to_port = -1
    protocol = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_tls"
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "ECS alb sec group"
  description = "Security group for load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "alb" {
  name               = "alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  ## load balancer is exposed to public subnets while internal services are behind private subnets
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
}

resource "aws_lb_target_group" alb {
  name        = "alb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  depends_on = [aws_lb.alb]
}

resource "aws_lb_listener" "alb_http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb.arn
  }
}

resource "aws_ecs_service" "node" {
  name                               = module.label.name
  cluster                            = aws_ecs_cluster.default.id
  task_definition                    = aws_ecs_task_definition.node.arn
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent 
  desired_count                      = 2
  launch_type                        = var.ecs_launch_type
  depends_on                         = [aws_lb_target_group.alb]

  load_balancer {
    target_group_arn = aws_lb_target_group.alb.arn
    container_name   = "forge"
    container_port   = 3000
  }

  network_configuration {
    assign_public_ip = false

    subnets          = [aws_subnet.private_az1.id, aws_subnet.private_az2.id]
    security_groups  = [aws_security_group.ecs_service.id]
  }
}

resource "aws_route53_zone" "primary" {
  name = "everlooksoftware.com"
}

resource "aws_route53_record" "primary" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "forge"
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = true
  }
}
