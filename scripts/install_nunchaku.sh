#!/bin/bash
# Install ComfyUI-Nunchaku and dependencies

echo "STAGE: Checking Nunchaku Installation"
cd /workspace/ComfyUI/custom_nodes

if [[ ! -d "ComfyUI-Nunchaku" ]]; then
    echo "Installing ComfyUI-Nunchaku..."
    git clone https://github.com/StartinDO/ComfyUI-Nunchaku.git
    
    echo "Installing Nunchaku Python dependencies..."
    # Attempt to install pre-built wheels or source
    # Note: Nunchaku usually requires specific CUDA compiled wheels. 
    # If they aren't in /wheels, we try pip.
    
    pip install nunchaku || echo "Warning: pip install nunchaku failed. Please provide wheels in /wheels."
    
    cd ComfyUI-Nunchaku
    pip install -r requirements.txt || true
    cd ..
else
    echo "ComfyUI-Nunchaku already installed."
fi
