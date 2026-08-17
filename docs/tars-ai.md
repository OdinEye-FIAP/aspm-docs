# TARS AI

Serviço de inteligência que enriquece findings persistidos pelo Pequod com análises estruturadas (summary, impact, recommendation, priority, confidence).

## Visão rápida

- Lê `finding` do banco do Pequod
- Envia para provider de IA configurável (mock, groq, huggingface, gemini)
- Persiste resultado em `finding_ai_analysis`

## Quick start

```bash
git clone https://github.com/OdinEye-FIAP/tars-ai.git
cd tars-ai
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python -m uvicorn main:app --host 0.0.0.0 --port 6060 --reload
```

## Endpoints úteis

- `GET /health` — status do serviço
- `GET /ai/pending` — findings pendentes
- `POST /ai/analyze-pending` — dispara análise
- `GET /ai/analyses` — lista análises geradas

## Links

- README completo: ../tars-ai/README.md
- TARS docs central: ../index.md
