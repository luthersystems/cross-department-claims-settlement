#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="my-mysql"
CONTAINER_NAME="mysql-server"

# Stop + remove old container if it exists
if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
  echo "Removing old container..."
  docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
fi

echo "Building image..."
docker build -t $IMAGE_NAME .

echo "Starting MySQL container..."
docker run --name $CONTAINER_NAME \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=claims_db \
  -e MYSQL_USER=testuser \
  -e MYSQL_PASSWORD=testpass \
  -p 3306:3306 \
  -d $IMAGE_NAME

echo "Waiting for MySQL to be ready..."
until docker exec $CONTAINER_NAME mysqladmin ping -h "127.0.0.1" --silent; do
  sleep 2
done

echo "✅ Database is ready with schema + seed data"
echo "Connection details:"
echo "  Host: host.docker.internal"
echo "  Port: 3306"
echo "  Database: claims_db"
echo "  Username: testuser"
echo "  Password: testpass"
