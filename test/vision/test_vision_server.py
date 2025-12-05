import requests
import base64
import json
import time
import sys

def test_server():
    print("⏳ Waiting for server to be ready...")
    url = "http://localhost:8081/chat/completions"
    
    # Wait for server
    for i in range(10):
        try:
            requests.get("http://localhost:8081/models")
            print("✅ Server is reachable!")
            break
        except:
            time.sleep(2)
            if i == 9:
                print("❌ Server not reachable after 20s")
                return

    # Download a safe image (Google Logo) to test with
    print("⬇️  Downloading test image...")
    try:
        img_url = "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png"
        img_data = requests.get(img_url).content
        base64_image = base64.b64encode(img_data).decode('utf-8')
        print("✅ Image downloaded and encoded")
    except Exception as e:
        print(f"❌ Failed to download test image: {e}")
        return

    payload = {
        "model": "mlx-community/LFM2-VL-3B-4bit",
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "What is this logo?"
                    },
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:image/png;base64,{base64_image}"
                        }
                    }
                ]
            }
        ],
        "max_tokens": 100
    }

    print("📤 Sending request (Base64)...")
    try:
        response = requests.post(url, headers={"Content-Type": "application/json"}, json=payload)
        print(f"📥 Status Code: {response.status_code}")
        if response.status_code == 200:
            print("✨ Response:")
            print(response.json()['choices'][0]['message']['content'])
        else:
            print(f"❌ Error: {response.text}")
    except Exception as e:
        print(f"❌ Request failed: {e}")

if __name__ == "__main__":
    test_server()
