# AWS E-commerce Infrastructure

This project provides a Terraform configuration to deploy a basic AWS infrastructure for an e-commerce application. It includes a VPC with public and private subnets, an Application Load Balancer (ALB), EC2 instances for the application, and a CloudFront distribution for content delivery.

## Architecture

The infrastructure consists of:

- **VPC**: Custom VPC with public subnets (for ALB and NAT gateways), private app subnets (for EC2 instances), and private DB subnets (for future database resources).
- **Networking**: Internet Gateway for public access, NAT Gateways for private subnet outbound traffic.
- **Security**: Security groups restricting access to HTTPS from CloudFront for ALB, and HTTP from ALB for app instances.
- **Load Balancing**: ALB with HTTPS listener (requires ACM certificate) and HTTP redirect to HTTPS.
- **Compute**: 3 EC2 instances running Amazon Linux 2 with Apache, serving a simple "Hello" page.
- **CDN**: CloudFront distribution pointing to the ALB for global content delivery.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.2.0
- AWS CLI configured with appropriate credentials and region (default: eu-west-2)
- An ACM certificate ARN for HTTPS (update `alb_certificate_arn` variable if needed)
- SSH key pair (optional, for instance access)

## Deployment

1. Clone the repository: git clone https://github.com/shi-deen/aws-ecommerce-infra.git
2. Navigate to the Terraform directory: cd terraform
3. Initialize Terraform: terraform init
4. Review the plan: terraform plan
5. Apply the configuration: terraform apply

6. Confirm with `yes` when prompted.

## Usage

- Access the application via the CloudFront domain (output: `cloudfront_domain`).
- The ALB redirects HTTP to HTTPS.
- EC2 instances are in private subnets; use SSH if a key is provided (update security group for your IP).

## Outputs

- `vpc_id`: The ID of the created VPC.
- `alb_dns_name`: DNS name of the Application Load Balancer.
- `cloudfront_domain`: Domain name of the CloudFront distribution.



