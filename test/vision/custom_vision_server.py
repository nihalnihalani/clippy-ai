import argparse
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List, Optional, Union, Dict, Any
import mlx.core as mx
from mlx_vlm import load, generate
from mlx_vlm.utils import load_image, process_image

# Define Request Models
class ImageUrl(BaseModel):
    url: str

class ContentItem(BaseModel):
    type: str
    text: Optional[str] = None
    image_url: Optional[ImageUrl] = None

class Message(BaseModel):
    role: str
    content: Union[str, List[ContentItem]]

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[Message]
    max_tokens: Optional[int] = 512
    temperature: Optional[float] = 0.7

# Initialize FastAPI
app = FastAPI(title="LFM2-VL Vision Server")

# Global model variables
model = None
processor = None
MODEL_PATH = "mlx-community/LFM2-VL-3B-4bit"

def load_model():
    global model, processor
    print(f"🚀 Loading model: {MODEL_PATH}")
    model, processor = load(MODEL_PATH)
    print("✅ Model loaded successfully")

@app.on_event("startup")
async def startup_event():
    load_model()

@app.post("/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    global model, processor
    
    if not model:
        raise HTTPException(status_code=500, detail="Model not loaded")

    # Extract text prompt and image
    prompt_text = ""
    image_url = None
    
    for message in request.messages:
        if message.role == "user":
            if isinstance(message.content, str):
                prompt_text = message.content
            elif isinstance(message.content, list):
                for item in message.content:
                    if item.type == "text":
                        prompt_text += item.text
                    elif item.type == "image_url":
                        image_url = item.image_url.url

    if not image_url:
        raise HTTPException(status_code=400, detail="No image provided")

    # Construct prompt manually for LFM2-VL using ChatML format found via transformers
    # Format: "<|startoftext|><|im_start|>user\n<image>{prompt}<|im_end|>\n<|im_start|>assistant\n"
    formatted_prompt = f"<|startoftext|><|im_start|>user\n<image>{prompt_text}<|im_end|>\n<|im_start|>assistant\n"

    try:
        # Load and process image
        image_input = image_url
        
        # Handle Base64 images manually to ensure compatibility
        if image_url.startswith("data:image"):
            try:
                import base64
                import io
                from PIL import Image as PILImage
                
                # Extract base64 data (data:image/jpeg;base64,...)
                header, encoded = image_url.split(",", 1)
                data = base64.b64decode(encoded)
                image_input = PILImage.open(io.BytesIO(data)).convert("RGB")
                print("✅ Successfully decoded Base64 image")
            except Exception as e:
                print(f"❌ Failed to decode Base64 image: {e}")
                raise HTTPException(status_code=400, detail=f"Invalid base64 image: {str(e)}")
            
        # Generate
        print(f"📝 Formatted Prompt: {formatted_prompt!r}")
        output = generate(
            model,
            processor,
            formatted_prompt,
            [image_input], # generate expects a list of images
            verbose=True, # Enable verbose to see generation in stdout
            max_tokens=request.max_tokens,
            temp=request.temperature
        )
        print(f"📤 Raw Output: {output.text!r}")
        
        return {
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "created": 1234567890,
            "model": request.model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": output.text
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0
            }
        }

    except Exception as e:
        print(f"Error during generation: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_PATH,
                "object": "model",
                "created": 1234567890,
                "owned_by": "mlx-community"
            }
        ]
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()
    
    uvicorn.run(app, host="0.0.0.0", port=args.port)
