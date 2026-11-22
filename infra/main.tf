# shortcut: state is stored locally (terraform.tfstate, git-ignored); use an S3 backend if anyone else runs this.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  name = "subnet-calculator" # must match APP_NAME in the pipeline (ECR repo, cluster, service, task family)
  # owner@ownerID/repo@repoID: GitHub's immutable OIDC subject, so a different repo later created
  # with the same name can't assume the role. From: gh api repos/{owner}/{repo}/actions/oidc/customization/sub
  github_repo = "abdulwaheed76@68082996/subnet-calculator@1466840055"
  region      = "eu-west-1" # must match AWS_REGION in the pipeline
}

provider "aws" {
  region = local.region
  default_tags {
    tags = { Project = local.name }
  }
}

data "aws_caller_identity" "me" {}
data "aws_availability_zones" "available" { state = "available" }

# ---------- Network: VPC with two public subnets in two AZs ----------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${local.name}-public-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------- Security groups: internet -> ALB:80 -> tasks:3000, nothing else in ----------

resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "app" {
  name   = "${local.name}-app"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "App port from the load balancer only"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    description = "Outbound for ECR image pulls and CloudWatch logs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Container registry ----------

resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE" # a commit-SHA tag can never be overwritten
  force_delete         = true        # lets `terraform destroy` remove it even with images inside
  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------- Load balancer ----------

resource "aws_lb" "app" {
  name               = local.name
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name                 = local.name
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip" # Fargate tasks register by their own IP, not by server
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 10

  health_check {
    path                = "/health"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------- ECS Fargate: cluster, task definition, service ----------

resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}

# Lets ECS pull the image from ECR and write container logs. The app itself needs no AWS access.
resource "aws_iam_role" "task_execution" {
  name = "${local.name}-task-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The pipeline copies the latest revision of this and swaps in the new image on every deploy.
# The :bootstrap tag doesn't exist, so tasks fail to start until the first pipeline deploy.
resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU
  memory                   = 512 # MB
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # GitHub's runners build x86 images
  }

  container_definitions = jsonencode([{
    name                   = "app" # must match container-name in the pipeline
    image                  = "${aws_ecr_repository.app.repository_url}:bootstrap"
    essential              = true
    readonlyRootFilesystem = true # the app never writes to disk
    portMappings           = [{ containerPort = 3000 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  # Rolling update: start new tasks first (200%), never drop below full capacity (100%).
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true # a version that fails health checks is replaced by the last working one
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # to reach ECR without a NAT gateway (~$35/month); the security group still blocks all inbound except the ALB
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    # The pipeline deploys new task definitions and auto scaling changes the count; don't undo them.
    ignore_changes = [task_definition, desired_count]
  }
}

# ---------- Auto scaling: 2-4 tasks, targeting ~100 requests per task per minute ----------

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2 # one per availability zone
  max_capacity       = 4 # caps the bill
}

# Request count, not CPU: this app is so light that CPU would almost never trigger scaling.
resource "aws_appautoscaling_policy" "requests" {
  name               = "requests-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 100
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}

# ---------- GitHub Actions login (OIDC): only pushes to main can assume this role ----------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github" {
  name = "${local.name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github" {
  name = "push-and-deploy"
  role = aws_iam_role.github.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      # These two ECS actions don't support resource-level restrictions.
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], Resource = "*" },
      # New revisions copy the Project tag; tagging on create needs TagResource. Only allowed while registering this family.
      {
        Effect    = "Allow"
        Action    = "ecs:TagResource"
        Resource  = "arn:aws:ecs:${local.region}:${data.aws_caller_identity.me.account_id}:task-definition/${local.name}:*"
        Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } }
      },
      { Effect = "Allow", Action = ["ecs:UpdateService", "ecs:DescribeServices"], Resource = aws_ecs_service.app.id },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.task_execution.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

# ---------- Values to copy into GitHub repo variables ----------

output "AWS_ROLE_ARN" {
  value = aws_iam_role.github.arn
}

output "APP_URL" {
  value = "http://${aws_lb.app.dns_name}"
}
