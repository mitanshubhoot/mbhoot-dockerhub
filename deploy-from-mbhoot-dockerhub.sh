#!/bin/bash

# Deploy Dsalta Vendor Profile from mbhoot/mbhoot-tprm Docker Hub Repository
# Usage: ./deploy-from-mbhoot-dockerhub.sh [version]

set -e

VERSION=${1:-latest}
REPOSITORY="mbhoot/mbhoot-tprm"

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}🚀 Deploying Dsalta Vendor Profile from Docker Hub...${NC}"
echo "Repository: $REPOSITORY"
echo "Version: $VERSION"

# Pull the images
echo -e "${BLUE}📥 Pulling images...${NC}"
docker pull $REPOSITORY-api:$VERSION
docker pull $REPOSITORY-consumer:$VERSION
docker pull postgres:15-alpine
docker pull redis:7-alpine

# Create docker-compose.yml if it doesn't exist
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${BLUE}📝 Creating docker-compose.yml...${NC}"
    cat > docker-compose.yml <<COMPOSE_EOF
version: '3.8'

services:
  # Redis for distributed deduplication
  redis:
    image: redis:7-alpine
    container_name: dsalta-redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - dsalta-network

  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: dsalta-postgres
    environment:
      POSTGRES_DB: dsalta_vendor_db
      POSTGRES_USER: dsalta
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-dsalta_secure_password}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dsalta -d dsalta_vendor_db"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    networks:
      - dsalta-network

  # API Server
  dsalta-api:
    image: $REPOSITORY-api:$VERSION
    container_name: dsalta-api-server
    environment:
      # Database
      DATABASE_URL: postgresql://dsalta:\${POSTGRES_PASSWORD:-dsalta_secure_password}@postgres:5432/dsalta_vendor_db
      
      # Redis for session/cache
      REDIS_URL: redis://redis:6379
      
      # Application Configuration
      NODE_ENV: production
      PORT: 3000
      LOG_LEVEL: \${LOG_LEVEL:-info}
      KAFKAJS_NO_PARTITIONER_WARNING: "1"
      
      # Security
      ENCRYPTION_KEY: \${ENCRYPTION_KEY:-your-encryption-key-here}
      
      # Google Cloud Storage Configuration
      GCP_PROJECT_ID: \${GCP_PROJECT_ID:-dsalta}
      GCS_BUCKET_NAME: \${GCS_BUCKET_NAME:-scanning-storage}
      GCS_SERVICE_ACCOUNT_KEY_PATH: \${GCS_SERVICE_ACCOUNT_KEY_PATH:-./dsalta-52250accd423.json}
      GCS_CACHE_DURATION_HOURS: \${GCS_CACHE_DURATION_HOURS:-24}
      
    ports:
      - "3000:3000"
    volumes:
      - ./logs:/app/logs
      - ./temp:/app/temp
      - ./dsalta-52250accd423.json:/app/dsalta-52250accd423.json:ro
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    # Auto-initialize services after startup
    command: >
      sh -c "
        npm run start &
        sleep 10 &&
        curl -X POST http://localhost:3000/api/init &&
        wait
      "
    networks:
      - dsalta-network

  # Kafka Consumer
  dsalta-consumer:
    image: $REPOSITORY-consumer:$VERSION
    container_name: dsalta-kafka-consumer
    environment:
      # Database
      DATABASE_URL: postgresql://dsalta:\${POSTGRES_PASSWORD:-dsalta_secure_password}@postgres:5432/dsalta_vendor_db
      
      # Redis for distributed deduplication
      REDIS_URL: redis://redis:6379
      
      # Kafka Configuration - PLAINTEXT
      KAFKA_BROKERS: \${KAFKA_BROKERS:-35.232.165.74:9094}
      KAFKA_SSL_ENABLED: \${KAFKA_SSL_ENABLED:-false}
      
      # Kafka Topics
      KAFKA_VENDOR_REQUEST_TOPIC: \${KAFKA_VENDOR_REQUEST_TOPIC:-new-vendor-request}
      KAFKA_VENDOR_RESPONSE_TOPIC: \${KAFKA_VENDOR_RESPONSE_TOPIC:-new-vendor-response}
      KAFKA_VENDOR_ERROR_TOPIC: \${KAFKA_VENDOR_ERROR_TOPIC:-new-vendor-error}
      
      # Application Configuration
      NODE_ENV: production
      LOG_LEVEL: \${LOG_LEVEL:-info}
      API_BASE_URL: http://dsalta-api:3000
      KAFKAJS_NO_PARTITIONER_WARNING: "1"
      
      # Security
      ENCRYPTION_KEY: \${ENCRYPTION_KEY:-your-encryption-key-here}
      
      # Rate Limiting
      KAFKA_CONSUMER_GROUP: \${KAFKA_CONSUMER_GROUP:-dsalta-vendor-consumer-group}
      KAFKA_PARTITION_CONCURRENCY: \${KAFKA_PARTITION_CONCURRENCY:-3}
      MAX_CONCURRENT_REQUESTS: \${MAX_CONCURRENT_REQUESTS:-10}
      REQUEST_TIMEOUT: \${REQUEST_TIMEOUT:-30000}
      
      # Google Cloud Storage Configuration
      GCP_PROJECT_ID: \${GCP_PROJECT_ID:-dsalta}
      GCS_BUCKET_NAME: \${GCS_BUCKET_NAME:-scanning-storage}
      GCS_SERVICE_ACCOUNT_KEY_PATH: \${GCS_SERVICE_ACCOUNT_KEY_PATH:-./dsalta-52250accd423.json}
      GCS_CACHE_DURATION_HOURS: \${GCS_CACHE_DURATION_HOURS:-24}
      
    volumes:
      - ./logs:/app/logs
      - ./temp:/app/temp
      - ./dsalta-52250accd423.json:/app/dsalta-52250accd423.json:ro
    depends_on:
      postgres:
        condition: service_healthy
      dsalta-api:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "node", "-e", "console.log('Consumer health check')"]
      interval: 30s
      timeout: 10s
      retries: 3
    command: ["node", "kafka-consumer-external-queue.js"]
    networks:
      - dsalta-network

volumes:
  postgres_data:
  redis_data:

networks:
  dsalta-network:
    driver: bridge
COMPOSE_EOF
fi

# Create .env file if it doesn't exist
if [ ! -f ".env" ]; then
    echo -e "${BLUE}📝 Creating .env file...${NC}"
    cat > .env <<ENV_EOF
# Database Configuration
POSTGRES_PASSWORD=dsalta_secure_password

# Redis Configuration
REDIS_URL=redis://redis:6379

# Kafka Configuration (GCP) - PLAINTEXT
KAFKA_BROKERS=35.232.165.74:9094
KAFKA_SSL_ENABLED=false

# Kafka Topics
KAFKA_VENDOR_REQUEST_TOPIC=new-vendor-request
KAFKA_VENDOR_RESPONSE_TOPIC=new-vendor-response
KAFKA_VENDOR_ERROR_TOPIC=new-vendor-error

# External API Keys
SHODAN_API_KEY=your-shodan-api-key

# Application Configuration
NODE_ENV=production
LOG_LEVEL=info

# Security
ENCRYPTION_KEY=your-32-character-encryption-key-here

# Google Cloud Storage Configuration
GCP_PROJECT_ID=dsalta
GCS_BUCKET_NAME=scanning-storage
GCS_SERVICE_ACCOUNT_KEY_PATH=./dsalta-52250accd423.json

# Rate Limiting
KAFKA_CONSUMER_GROUP=dsalta-vendor-consumer-group
KAFKA_PARTITION_CONCURRENCY=3
MAX_CONCURRENT_REQUESTS=10
REQUEST_TIMEOUT=30000
ENV_EOF
    
    echo -e "${YELLOW}⚠️  Please edit .env file with your actual configuration values${NC}"
fi

# Create necessary directories
mkdir -p logs temp

# Start the services
echo -e "${BLUE}🚀 Starting services...${NC}"
docker-compose up -d

echo -e "${GREEN}✅ Deployment completed!${NC}"
echo "📊 Services running:"
echo "   - PostgreSQL: localhost:5432"
echo "   - Redis: localhost:6379 (external queue)"
echo "   - API Server: http://localhost:3000"
echo "   - Kafka Consumer: Running with external queue"
echo ""
echo -e "${YELLOW}🔧 Next Steps - Start Queue Processor:${NC}"
echo "   1. Wait for API server to be ready (check health endpoint)"
echo "   2. Start queue processor: curl -X POST http://localhost:3000/api/queue/start"
echo "   3. Check queue status: curl -X GET http://localhost:3000/api/queue/start"
echo ""
echo "📝 Useful commands:"
echo "   - View logs: docker-compose logs -f"
echo "   - View specific service logs: docker-compose logs -f dsalta-api"
echo "   - API health check: curl http://localhost:3000/api/health"
echo "   - Queue status: curl http://localhost:3000/api/queue/start"
echo "   - Stop services: docker-compose down"
echo "   - Restart: docker-compose restart"
echo "   - Check status: docker-compose ps"
