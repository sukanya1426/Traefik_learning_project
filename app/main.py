from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import os

app = FastAPI(
    title="Traefik FastAPI Demo",
    description="FastAPI app running behind Traefik with HTTPS and basic auth on Hetzner",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve static files (the dashboard UI)
_static_dir = os.path.join(os.path.dirname(__file__), "static")
app.mount("/static", StaticFiles(directory=_static_dir), name="static")


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class Item(BaseModel):
    id: int
    name: str
    description: Optional[str] = None
    price: float


class ItemCreate(BaseModel):
    name: str
    description: Optional[str] = None
    price: float


# ---------------------------------------------------------------------------
# In-memory store (replace with a real DB for production)
# ---------------------------------------------------------------------------

_items: List[Item] = [
    Item(id=1, name="Widget",     description="A very useful widget",  price=9.99),
    Item(id=2, name="Gadget",     description="A cool gadget",         price=29.99),
    Item(id=3, name="Doohickey",  description="You'll know when you need it", price=4.99),
]
_next_id = 4


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def ui():
    """Serve the dashboard UI."""
    with open(os.path.join(_static_dir, "index.html")) as f:
        return f.read()


@app.get("/info")
def info():
    """API info / welcome message."""
    return {
        "message": "Hello from FastAPI + Traefik!",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "docs": "/docs",
        "items": "/items",
    }


@app.get("/health")
def health():
    """Used by monitoring / load balancers to check liveness."""
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat() + "Z"}


@app.get("/items", response_model=List[Item])
def list_items():
    """Return all items."""
    return _items


@app.get("/items/{item_id}", response_model=Item)
def get_item(item_id: int):
    """Return a single item by ID."""
    for item in _items:
        if item.id == item_id:
            return item
    raise HTTPException(status_code=404, detail=f"Item {item_id} not found")


@app.post("/items", response_model=Item, status_code=201)
def create_item(payload: ItemCreate):
    """Create a new item."""
    global _next_id
    item = Item(id=_next_id, **payload.model_dump())
    _next_id += 1
    _items.append(item)
    return item


@app.delete("/items/{item_id}", status_code=204)
def delete_item(item_id: int):
    """Delete an item by ID."""
    for i, item in enumerate(_items):
        if item.id == item_id:
            _items.pop(i)
            return
    raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
