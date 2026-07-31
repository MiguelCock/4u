# Create a virtual environment (creates a folder named 'myenv')
python3 -m venv myenv

# Activate it:
source myenv/bin/activate   # Linux/macOS
source myenv/bin/activate.fish

# Now your prompt changes to (myenv) and pip installs go here
pip install -r requiriments.txt

# Exit when done:
deactivate

---

python3 train.py

python3 predict.py foto_nueva.jpg

python3 api.py

uso: curl -X POST -F "file=@foto.jpg" http://localhost:8000/predict
