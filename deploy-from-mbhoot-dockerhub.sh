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
      
      # Security
      ENCRYPTION_KEY: \${ENCRYPTION_KEY:-your-encryption-key-here}
      
    ports:
      - "3000:3000"
    volumes:
      - ./logs:/app/logs
      - ./temp:/app/temp
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
    command: ["npm", "run", "start"]
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
      
      # Kafka Configuration
      KAFKA_BROKERS: \${KAFKA_BROKERS:-35.225.196.0:9094}
      KAFKA_USERNAME: \${KAFKA_USERNAME:-dsalta}
      KAFKA_PASSWORD: \${KAFKA_PASSWORD:-Dsalta@Toronto.}
      KAFKA_SSL_ENABLED: \${KAFKA_SSL_ENABLED:-true}
      KAFKA_SASL_MECHANISM: \${KAFKA_SASL_MECHANISM:-SCRAM-SHA-256}
      
      # Kafka Topics
      KAFKA_VENDOR_REQUEST_TOPIC: \${KAFKA_VENDOR_REQUEST_TOPIC:-vendor-request-topic}
      KAFKA_VENDOR_RESPONSE_TOPIC: \${KAFKA_VENDOR_RESPONSE_TOPIC:-vendor-response-topic}
      KAFKA_VENDOR_ERROR_TOPIC: \${KAFKA_VENDOR_ERROR_TOPIC:-vendor-error-topic}
      
      # Application Configuration
      NODE_ENV: production
      LOG_LEVEL: \${LOG_LEVEL:-info}
      API_BASE_URL: http://dsalta-api:3000
      
      # Security
      ENCRYPTION_KEY: \${ENCRYPTION_KEY:-your-encryption-key-here}
      
      # Rate Limiting
      KAFKA_CONSUMER_GROUP: \${KAFKA_CONSUMER_GROUP:-dsalta-vendor-consumer-group}
      KAFKA_PARTITION_CONCURRENCY: \${KAFKA_PARTITION_CONCURRENCY:-3}
      MAX_CONCURRENT_REQUESTS: \${MAX_CONCURRENT_REQUESTS:-10}
      REQUEST_TIMEOUT: \${REQUEST_TIMEOUT:-30000}
      
    volumes:
      - ./logs:/app/logs
      - ./temp:/app/temp
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
    command: ["node", "kafka-consumer.js"]
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

# Kafka Configuration (GCP)
KAFKA_BROKERS=35.225.196.0:9094
KAFKA_USERNAME=dsalta
KAFKA_PASSWORD=Dsalta@Toronto.
KAFKA_SSL_ENABLED=true
KAFKA_SASL_MECHANISM=SCRAM-SHA-256

# Kafka Topics
KAFKA_VENDOR_REQUEST_TOPIC=vendor-request-topic
KAFKA_VENDOR_RESPONSE_TOPIC=vendor-response-topic
KAFKA_VENDOR_ERROR_TOPIC=vendor-error-topic

# External API Keys
SHODAN_API_KEY=your-shodan-api-key

# Application Configuration
NODE_ENV=production
LOG_LEVEL=info

# Security
ENCRYPTION_KEY=your-32-character-encryption-key-here

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
echo "   - Redis: localhost:6379 (deduplication)"
echo "   - API Server: http://localhost:3000"
echo "   - Kafka Consumer: Running in background"
echo ""
echo "📝 Useful commands:"
echo "   - View logs: docker-compose logs -f"
echo "   - View specific service logs: docker-compose logs -f dsalta-api"
echo "   - Stop services: docker-compose down"
echo "   - Restart: docker-compose restart"
echo "   - Check status: docker-compose ps"
