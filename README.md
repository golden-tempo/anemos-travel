# Travel Route Planner

A comprehensive travel route planning platform with Go API backend and beautiful Flutter mobile app frontend.

## Features

### 🚀 **Go API Backend**
- RESTful API endpoints with comprehensive route optimization
- JSON request/response with detailed metrics and timing
- CORS support and logging middleware
- Health check and API versioning (v1)
- Docker containerization for easy deployment

### 📱 **Flutter Mobile App**
- Beautiful Material Design 3 interface
- Real-time route optimization with visual results
- Location management with operating hours support
- Country planning with seasonal intelligence
- State management with Riverpod for smooth UX
- Type-safe API integration with comprehensive error handling

## Prerequisites

### Go API Development
- Go 1.21 or higher
- Git (for cloning and dependency management)
- **Google Places API Key** (for location search and geocoding)

### Flutter App Development  
- Flutter SDK (latest stable version)
- iOS Simulator / Android Emulator or physical device

### Google Places API Setup
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the Places API
4. Create credentials (API Key)
5. Set the `GOOGLE_PLACES_API_KEY` environment variable (see Configuration section below)

### Docker Development
- Docker
- Docker Compose (optional, for easier development)

## Configuration

### Environment Variables
Set the following environment variable before running the API:

```bash
export GOOGLE_PLACES_API_KEY="your_google_places_api_key_here"
```

Or create a `.env` file in the `src/packages/api/` directory:
```
GOOGLE_PLACES_API_KEY=your_google_places_api_key_here
```

**Note:** The API will work without this key, but location search features will be disabled.

## Local Development

To install dependencies and start the application locally (without Docker):

```bash
# Install Go module deps + Flutter packages
make setup

# Run the API locally on http://localhost:8080
make api-run

# In another terminal, run the Flutter app against the local API
make flutter-run
```

See `make help` for the full list of available commands (tests, formatting, Docker stacks, etc.).

## Installation & Running

### Quick Start with Makefile (Recommended)

```bash
# Setup the entire project (API + Flutter dependencies)
make setup

# Development: Flutter hot reload + API behind one gateway
make docker-dev

# Deployment: static Flutter build + API behind one gateway
make docker-deploy

# Local API only (port 8080)
make api-run

# Local Flutter (points at local API on :8080)
make flutter-run

# Run API tests
make test

# See all available commands
make help
```

### Option 1: Docker (Recommended)

Docker orchestration lives in [`dockerize/`](dockerize/README.md). A single nginx **gateway** on port **3000** serves the Flutter app and proxies `/api/` to the Go API (same origin — no CORS issues).

```bash
# Development: hot reload
make docker-dev

# Deployment: static production-like build
make docker-deploy

# Stop stacks
make docker-stop
```

| Stack | App URL | API (via gateway) |
|-------|---------|-------------------|
| Development | http://localhost:3000 | http://localhost:3000/api/v1 |
| Deployment | http://localhost:3000/app/ | http://localhost:3000/api/v1 |

Set `GOOGLE_PLACES_API_KEY` in `src/packages/api/.env` for place search.

### Option 2: Local Development

1. Navigate to the API directory:
```bash
cd src/packages/api
```

2. Download dependencies:
```bash
go mod tidy
```

3. Start the server:
```bash
go run .
```

### Verification

The server will start on port 8080. You'll see output similar to:
```
Starting Travel Route Planner API server on port 8080
Available endpoints:
  GET /                  - Hello World
  GET /hello             - Hello World
  GET /health            - Health Check
  GET /api/v1/hello      - Hello World (v1)
  GET /api/v1/health     - Health Check (v1)
```

## API Endpoints

### Root Endpoints

- `GET /` - Returns a hello world message
- `GET /hello` - Returns a hello world message
- `GET /health` - Returns server health status

### Versioned API Endpoints (v1)

- `GET /api/v1/hello` - Returns a hello world message
- `GET /api/v1/health` - Returns server health status
- `POST /api/v1/optimize-route` - Optimizes a route for visiting multiple locations

## Example Responses

### Hello World Endpoint
```bash
curl http://localhost:8081/hello
```

Response:
```json
{
  "message": "Hello, World! Welcome to the Travel Route Planner API!",
  "status": "success"
}
```

### Health Check Endpoint
```bash
curl http://localhost:8081/health
```

Response:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-15T10:30:45Z",
  "service": "travel-route-planner-api"
}
```

### Route Optimization Endpoint
```bash
curl -X POST http://localhost:8081/api/v1/optimize-route \
  -H "Content-Type: application/json" \
  -d '{
    "locations": [
      {
        "id": "starbucks",
        "name": "Starbucks Times Square",
        "latitude": 40.7589,
        "longitude": -73.9851,
        "address": "1585 Broadway, New York, NY 10036",
        "category": "coffee_shop",
        "hours": {
          "monday": "06:00-22:00",
          "tuesday": "06:00-22:00",
          "wednesday": "06:00-22:00",
          "thursday": "06:00-22:00",
          "friday": "06:00-22:00",
          "saturday": "06:30-22:00",
          "sunday": "06:30-21:00"
        }
      },
      {
        "id": "empire_state",
        "name": "Empire State Building",
        "latitude": 40.7484,
        "longitude": -73.9857,
        "address": "350 5th Ave, New York, NY 10118",
        "category": "tourist_attraction",
        "hours": {
          "monday": "10:00-22:00",
          "tuesday": "10:00-22:00",
          "wednesday": "10:00-22:00",
          "thursday": "10:00-22:00",
          "friday": "10:00-22:00",
          "saturday": "09:00-23:00",
          "sunday": "09:00-22:00"
        }
      }
    ],
    "start_index": 0,
    "start_time": "09:00",
    "start_date": "2024-03-15",
    "return_to_start": true
  }'
```

Response:
```json
{
  "optimized_route": [
    {
      "id": "starbucks",
      "name": "Starbucks Times Square",
      "latitude": 40.7589,
      "longitude": -73.9851,
      "address": "1585 Broadway, New York, NY 10036"
    },
    {
      "id": "empire_state",
      "name": "Empire State Building",
      "latitude": 40.7484,
      "longitude": -73.9857,
      "address": "350 5th Ave, New York, NY 10118"
    },
    {
      "id": "central_park",
      "name": "Central Park",
      "latitude": 40.7829,
      "longitude": -73.9654,
      "address": "Central Park, New York, NY"
    }
  ],
  "total_distance_km": 3.42,
  "total_travel_time_minutes": 6,
  "total_visit_time_minutes": 105,
  "total_trip_time_minutes": 111,
  "location_timings": [
    {
      "location": {
        "id": "starbucks",
        "name": "Starbucks Times Square",
        "latitude": 40.7589,
        "longitude": -73.9851,
        "category": "coffee_shop"
      },
      "arrival_time": "09:00",
      "visit_duration_minutes": 15,
      "departure_time": "09:15",
      "travel_to_next_minutes": 2
    },
    {
      "location": {
        "id": "empire_state",
        "name": "Empire State Building",
        "latitude": 40.7484,
        "longitude": -73.9857,
        "category": "tourist_attraction",
        "hours": {
          "monday": "10:00-22:00"
        }
      },
      "arrival_time": "10:00",
      "visit_duration_minutes": 45,
      "departure_time": "10:45",
      "travel_to_next_minutes": 0
    }
  ],
  "location_count": 3,
  "algorithm_used": "nearest-neighbor + 2-opt",
  "original_distance_km": 3.89,
  "improvement_percentage": 12.08,
  "status": "success"
}
```

#### Route Optimization Request Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `locations` | Array | Yes | Array of location objects (max 50) |
| `locations[].id` | String | Yes | Unique identifier for the location |
| `locations[].name` | String | Yes | Human-readable name for the location |
| `locations[].latitude` | Number | Yes | Latitude (-90 to 90) |
| `locations[].longitude` | Number | Yes | Longitude (-180 to 180) |
| `locations[].address` | String | No | Optional address string |
| `locations[].category` | String | No | Location category for visit time estimation |
| `locations[].visit_duration_minutes` | Number | No | Override estimated visit time (minutes) |
| `locations[].hours` | Object | No | Operating hours by day of week |
| `locations[].hours.monday` | String | No | Monday hours (e.g., "09:00-17:00" or "closed") |
| `locations[].hours.tuesday` | String | No | Tuesday hours |
| `locations[].hours.wednesday` | String | No | Wednesday hours |
| `locations[].hours.thursday` | String | No | Thursday hours |
| `locations[].hours.friday` | String | No | Friday hours |
| `locations[].hours.saturday` | String | No | Saturday hours |
| `locations[].hours.sunday` | String | No | Sunday hours |
| `start_index` | Number | No | Index of starting location (default: 0) |
| `start_time` | String | No | Start time in "HH:MM" format (24-hour) |
| `start_date` | String | No | Start date in "YYYY-MM-DD" format |
| `return_to_start` | Boolean | No | Whether to return to starting point (default: false) |

#### Supported Location Categories

| Category | Default Visit Time | Description |
|----------|-------------------|-------------|
| `coffee_shop` | 15 min | Quick coffee stop |
| `restaurant` | 60 min | Full meal |
| `fast_food` | 20 min | Quick meal |
| `museum` | 90 min | Cultural visit |
| `art_gallery` | 75 min | Art viewing |
| `store` | 30 min | Shopping |
| `grocery_store` | 25 min | Grocery shopping |
| `department_store` | 45 min | Larger shopping trip |
| `bank` | 10 min | Banking transaction |
| `atm` | 3 min | Quick cash withdrawal |
| `gas_station` | 5 min | Fuel stop |
| `tourist_attraction` | 45 min | Sightseeing |
| `park` | 30 min | Park visit |
| `beach` | 60 min | Beach time |
| `gym` | 75 min | Workout |
| `hospital` | 45 min | Medical appointment |
| `pharmacy` | 10 min | Prescription pickup |
| `library` | 40 min | Reading/research |
| `unknown` | 20 min | Default fallback |

#### Operating Hours Format

Operating hours should be specified in 24-hour format using the pattern `"HH:MM-HH:MM"` or `"closed"`:

- **Standard hours**: `"09:00-17:00"` (9 AM to 5 PM)
- **Late night**: `"18:00-02:00"` (6 PM to 2 AM next day)
- **Closed**: `"closed"` or omit the day entirely
- **24/7**: Omit the `hours` field entirely

**Examples:**
```json
"hours": {
  "monday": "09:00-17:00",
  "tuesday": "09:00-17:00", 
  "wednesday": "09:00-17:00",
  "thursday": "09:00-17:00",
  "friday": "09:00-17:00",
  "saturday": "10:00-16:00",
  "sunday": "closed"
}
```

**Time-Aware Behavior:**
- If you arrive before a location opens, the system waits until opening time
- Routes automatically adjust to respect business hours
- Closed days are handled by finding the next available day
- Late-night hours (crossing midnight) are supported

## Building for Production

### Docker Production Build
```bash
# Build optimized production image
docker build -t travel-route-planner:latest .

# Tag for registry (optional)
docker tag travel-route-planner:latest your-registry.com/travel-route-planner:latest

# Push to registry (optional)
docker push your-registry.com/travel-route-planner:latest
```

### Local Binary Build
```bash
# Navigate to API directory
cd src/packages/api

# Build the binary
go build -o travel-route-planner .

# Run the binary
./travel-route-planner
```

## Project Structure

```
travel-route-planner/
├── src/
│   └── packages/
│       ├── api/                    # Go API backend
│       │   ├── main.go             # Main application file with HTTP server
│       │   ├── route_optimizer.go  # Location route optimization algorithms (2-Opt)
│       │   ├── go.mod              # Go module definition
│       │   ├── go.sum              # Go module checksums
│       │   ├── Dockerfile          # Docker build configuration
│       │   ├── test_data.json      # Sample test data for location routing
│       │   ├── test_countries.json # Sample test data for country routing
│       │   └── test_examples.sh    # Automated test script
│       └── flutter-app/            # Flutter mobile app
│           ├── lib/                # Flutter source code
│           │   ├── main.dart       # App entry point
│           │   ├── models/         # Data models (matching Go API)
│           │   ├── services/       # API client
│           │   ├── providers/      # Riverpod state management
│           │   ├── screens/        # Main app screens
│           │   └── widgets/        # Reusable UI components
│           ├── test/               # Flutter tests
│           └── pubspec.yaml        # Flutter dependencies
├── docker-compose.yml              # Docker Compose configuration
├── .dockerignore                   # Docker ignore patterns
├── .gitignore                      # Git ignore patterns
└── README.md                       # This file
```

## Middleware

The application includes two middleware components:

1. **Logging Middleware**: Logs all incoming requests with method, URI, remote address, and response time
2. **CORS Middleware**: Adds Cross-Origin Resource Sharing headers for frontend integration

## Route Optimization Features

### Location-Level Optimization
- **Algorithm**: Nearest Neighbor + 2-Opt optimization
- **Capacity**: Supports up to 50 locations efficiently
- **Performance**: Typically optimizes routes in 10-50ms
- **Quality**: Usually within 5-15% of optimal solution
- **Flexibility**: Optional starting point and round-trip options
- **Visit Time Estimation**: Category-based time estimates with custom overrides
- **Operating Hours Integration**: Validates location hours and adjusts arrival times
- **Time-Aware Planning**: Automatically waits for closed locations to open
- **Detailed Timing**: Real arrival/departure times with travel time separation
- **Flexible Scheduling**: Supports custom start times and dates

### Country-Level Optimization
- **Multi-Country Planning**: Optimizes routes across up to 20 countries
- **Seasonal Intelligence**: Considers ideal travel seasons and weather patterns
- **Distance Optimization**: Minimizes travel distances between countries
- **Balanced Approach**: Combines seasonal and distance factors
- **Weather Ratings**: Provides 1-10 weather ratings for each country visit
- **Trip Duration Planning**: Distributes time optimally across countries
- **Seasonal Avoidance**: Automatically avoids unfavorable travel periods
- **Continental Awareness**: Understands regional travel patterns

### Comprehensive Metrics
- Distance, time estimates, and improvement statistics
- Seasonal optimization scores and weather ratings
- Travel vs. stay time breakdowns
- Multiple optimization strategy comparisons

## Testing

### Quick Test
```bash
# Start the server
docker-compose up --build

# Run automated tests (navigate to API directory first)
cd src/packages/api
./test_examples.sh
```

### Manual Testing
```bash
# Simple 3-location test (from API directory)
cd src/packages/api
curl -X POST http://localhost:8081/api/v1/optimize-route \
  -H "Content-Type: application/json" \
  -d @test_data.json
```

## Docker Features

### API Container
- **Multi-stage build**: Optimized for small production images
- **Security**: Non-root user execution
- **Health checks**: Automated service monitoring
- **Graceful shutdown**: Proper signal handling

### Web App Container
- **Multi-stage build**: Flutter compilation + nginx serving
- **Production optimized**: Compiled Flutter web with optimized assets
- **Nginx serving**: High-performance static file serving with proper headers
- **PWA support**: Service worker and manifest for Progressive Web App features
- **Health checks**: Built-in health monitoring
- **Development ready**: Docker Compose with hot-reload capability
- **Production ready**: Optimized Alpine Linux base image

## Next Steps

This skeleton provides a solid foundation for building a travel route planner API. Consider adding:

- Database integration (PostgreSQL/Redis examples in docker-compose.yml)
- Authentication and authorization
- Route planning algorithms
- User management
- Trip planning endpoints
- Geographic data integration
- Testing framework
- CI/CD pipeline
- Kubernetes deployment manifests
- Environment-specific configurations
