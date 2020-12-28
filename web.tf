provider "aws" {
  region = "us-east-2"
}

data "aws_vpc" "default" {
  default = true
}

variable "server_http_port" {
  description = "Web servers http port"
  type        = number
  default     = 8080
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

#-----------------------------------------------------------------------------------
# The launch configuration is the immutable description of the 
# instances that will be targets of an autoscale group
#   - UBUNTU
#   - Simple Webserver on server_port showing host info to verify load balancing
#-----------------------------------------------------------------------------------
resource "aws_launch_configuration" "webserver" {
  image_id = "ami-0c55b159cbfafe1f0"
  instance_type = "t2.micro"
  security_groups = [aws_security_group.webinstance.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Web Server: \n" `uname -a` > index.html
              nohup busybox httpd -f -p ${var.server_http_port} &
              EOF
 
  # Set lifecycle so Terraform can build up a new instance before
  # destroy, so the autoscale group can coordinate updates
  lifecycle {
    create_before_destroy = true
  }
}

#-----------------------------------------------------------------------------------
# The web server autoscale group definition 
# Depends on the launch configuration 
#-----------------------------------------------------------------------------------
resource "aws_autoscaling_group" "webasg" {
  launch_configuration = aws_launch_configuration.webserver.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids 

  target_group_arns = [aws_lb_target_group.web-asg-tg.arn]
  health_check_type = "ELB"

  min_size = 2
  max_size = 4

  tag {
    key                 = "Name"
    value               = "terraform-asg-webserver"
    propagate_at_launch = true
  }
}

#-----------------------------------------------------------------------------------
# ALB: Application load balancer for L7
#-----------------------------------------------------------------------------------
resource "aws_lb" "webalb" {
  name                  = "web-asg"
  load_balancer_type    = "application"
  subnets               = data.aws_subnet_ids.default.ids
  security_groups       = [aws_security_group.web-alb-sg.id]
}

#-----------------------------------------------------------------------------------
# ALB listener, declare what traffic is balanced so we can handle unwanted 
#-----------------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn     = aws_lb.webalb.arn
  port                  = 80
  protocol              = "HTTP"
 
  # For requests not matching the listener port/protocol, respond this way:
  default_action {
    type = "fixed-response"
    
    fixed_response {
      content_type = "text/plain"
      message_body = "Go away"
      status_code = 404
    }
  }
}

#-----------------------------------------------------------------------------------
# Security group for alb load balancer
#-----------------------------------------------------------------------------------
resource "aws_security_group" "web-alb-sg" {
  name = "named-web-alb-sg"
  
  # Allow port http inbound
  ingress {
    from_port          = 80
    to_port            = 80
    protocol           = "tcp"
    cidr_blocks        = ["0.0.0.0/0"]
  }
  # For health checks allow all outbound (shortcut)
  egress {
    from_port          = 0
    to_port            = 0
    protocol           = "-1"
    cidr_blocks        = ["0.0.0.0/0"]
  }
}

#-----------------------------------------------------------------------------------
# Security group for webservers
#-----------------------------------------------------------------------------------
resource "aws_security_group" "webinstance" {
  name = "terraform-example-instance"

  ingress {
    from_port      = 8080
    to_port        = 8080
    protocol       = "tcp"
    cidr_blocks    = ["0.0.0.0/0"]
  }
  egress {
    from_port      = 0 
    to_port        = 0  
    protocol       = "-1"
    cidr_blocks    = ["0.0.0.0/0"]
  }
}

#-----------------------------------------------------------------------------------
# Define the target group used with the autoscale group
# The target group defines the health checking, for http servers
# checking periodically for HTTP 200 OK is used 
#-----------------------------------------------------------------------------------
resource "aws_lb_target_group" "web-asg-tg" {
  name     = "named-web-asg-tg"
  port     = var.server_http_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

#-----------------------------------------------------------------------------------
# Setup listener rule: ALB gets requets, allow ALB to forward all paths to our ASG
#-----------------------------------------------------------------------------------
resource "aws_lb_listener_rule" "asg-listen" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100
   
  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web-asg-tg.arn
  }
}

output "alb_dns_name" {
  value           = aws_lb.webalb.dns_name
  description     = "Public address for load balanced webserver"
}

 





