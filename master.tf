data "aws_route53_zone" "dns_zone" {
  name = "${var.domain_name}"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "available" {
  vpc_id = "${data.aws_vpc.default.id}"
}

resource "aws_security_group" "rancher-elb" {
  name   = "${var.prefix}-rancher-elb"
  vpc_id = "${data.aws_vpc.default.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rancher" {
  name   = "${var.prefix}-rancher-server"
  vpc_id = "${data.aws_vpc.default.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "TCP"
    security_groups = ["${aws_security_group.rancher-elb.id}"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K8s kube-api for kubectl
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K8s NodePorts
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Open intra-cluster
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "template_cloudinit_config" "rancherserver-cloudinit" {
  part {
    content_type = "text/cloud-config"
    content      = "hostname: ${var.prefix}-rancherserver\nmanage_etc_hosts: true"
  }

  part {
    content_type = "text/x-shellscript"
    content      = "${data.template_file.userdata_server.rendered}"
  }
}

resource "aws_instance" "rancher" {
  count         = "${var.rancher_master_node_count}"
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "${var.instance_type}"
  key_name      = "${var.ssh_key_name}"

  vpc_security_group_ids      = ["${aws_security_group.rancher.id}"]
  subnet_id                   = "${data.aws_subnet_ids.available.ids[0]}"
  associate_public_ip_address = true
  #user_data       = "${data.template_cloudinit_config.rancherserver-cloudinit.rendered}"
  #  iam_instance_profile = "k8s-ec2-route53"

  root_block_device = {
    volume_type = "gp2"
    volume_size = "50"
  }
  tags = {
    "Name" = "${var.prefix}-${count.index}"
  }
}

resource "aws_elb" "rancher" {
  name            = "${var.prefix}"
  subnets         = ["${data.aws_subnet_ids.available.ids[0]}"]
  security_groups = ["${aws_security_group.rancher-elb.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  listener {
    instance_port     = 443
    instance_protocol = "tcp"
    lb_port           = 443
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "tcp:80"
    interval            = 5
  }

  instances    = ["${aws_instance.rancher.*.id}"]
  idle_timeout = 1800

  tags {
    Name = "${var.prefix}"
  }
}

# DNS
resource "aws_route53_record" "rancher" {
  zone_id = "${data.aws_route53_zone.dns_zone.zone_id}"
  name    = "${var.prefix}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = "${aws_elb.rancher.dns_name}"
    zone_id                = "${aws_elb.rancher.zone_id}"
    evaluate_target_health = true
  }
}
