# Thrive

A Flutter mobile application powered by a Python FastAPI backend.

## Prerequisites

### Backend (ThriveAPI)
- A free API key from [Groq](https://console.groq.com)

### Frontend (thriveapp)
- Flutter SDK
- Firebase project set up

## Setup

### Backend
1. Navigate to the `ThriveAPI` folder
2. Install dependencies:
pip install -r requirements.txt
3. Create a `.env` file based on `.env.example` and add your Groq API key:
GROQ_API_KEY=your_key_here
4. Run the API:
uvicorn main:app --reload

### Frontend
1. Navigate to the `thriveapp` folder
2. Install dependencies:
flutter pub get
3. Run the app:
flutter run

