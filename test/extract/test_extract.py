import requests
import json
import time

def test_extract():
    print("⏳ Waiting for Extract server (8083)...")
    url = "http://localhost:8083/v1/chat/completions"
    
    # Wait for server
    for i in range(10):
        try:
            requests.get("http://localhost:8083/v1/models")
            print("✅ Server is reachable!")
            break
        except:
            time.sleep(2)
            if i == 9:
                print("❌ Server not reachable after 20s")
                return

    payload = {
        "model": "LiquidAI/LFM2-1.2B-Extract",
        "messages": [
            {
                "role": "user",
                "content": "Extract the name and date from this text: 'Meeting with John Doe on 2023-10-27.'"
            }
        ],
        "max_tokens": 100
    }

    print("📤 Sending Extract request...")
    try:
        response = requests.post(url, headers={"Content-Type": "application/json"}, json=payload)
        if response.status_code == 200:
            print("✨ Response:")
            print(response.json()['choices'][0]['message']['content'])
        else:
            print(f"❌ Error: {response.text}")
    except Exception as e:
        print(f"❌ Request failed: {e}")

if __name__ == "__main__":
    test_extract()
