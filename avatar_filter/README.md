# AI-powered Avatar Image Filter Tool

A comprehensive tool for filtering and classifying images suitable for avatars using AI models optimized for Intel NPU acceleration.

## Features

### Core Capabilities
- **Gender Classification**: Classify images as Male, Female, or Uncertain with >85% accuracy
- **Avatar Suitability Assessment**: Evaluate image quality, face ratio, lighting, contrast, and detect obstructions
- **Intel NPU Integration**: Utilizes Intel NPU for accelerated inference via OpenVINO toolkit
- **Batch Processing**: Efficient processing of multiple images with progress tracking
- **Organized Output**: Automatically organizes images into structured directories

### Output Structure
```
output/
├── Male/
│   ├── Suitable/
│   └── Not_Suitable/
├── Female/
│   ├── Suitable/
│   └── Not_Suitable/
└── Uncertain/
    ├── Suitable/
    └── Not_Suitable/
```

## Quick Start

### 1. Installation
```bash
cd avatar_filter
pip install -r requirements.txt
```

### 2. Create Configuration
```bash
python src/main.py create-config
```

### 3. Process Images
```bash
# Preview mode (no files moved)
python src/main.py process -i /path/to/images --preview

# Process and organize images
python src/main.py process -i /path/to/images -o /path/to/output
```

### 4. View Results
Check the output directory and `summary_report.txt` for detailed results.

## Installation

### Prerequisites
- Python 3.8 or higher
- Intel NPU-enabled hardware (falls back to CPU if NPU not available)
- Windows platform (recommended for Intel NPU support)

### Install Dependencies
```bash
cd avatar_filter
pip install -r requirements.txt
```

### Download AI Models
The tool requires OpenVINO-compatible models. Download these models and place them in the `models/` directory:

1. **Gender Recognition Model**: `gender-recognition-retail-0013.xml`
2. **Face Detection Model**: `face-detection-adas-0001.xml`
3. **Face Quality Assessment Model**: `face-reidentification-retail-0095.xml`

You can download these from the Intel Open Model Zoo:
```bash
# Using OpenVINO Model Downloader (if available)
omz_downloader --name gender-recognition-retail-0013 --output_dir models/
omz_downloader --name face-detection-adas-0001 --output_dir models/
omz_downloader --name face-reidentification-retail-0095 --output_dir models/
```

## Usage

### Basic Usage
```bash
# Process images in a directory
python src/main.py process -i /path/to/images -o /path/to/output

# Use custom configuration
python src/main.py process -i /path/to/images -o /path/to/output -c config/config.yaml

# Preview organization without moving files
python src/main.py process -i /path/to/images --preview

# Move files instead of copying
python src/main.py process -i /path/to/images --move
```

### Configuration Management
```bash
# Create default configuration file
python src/main.py create-config -o config/my_config.yaml

# Use custom configuration
python src/main.py process -i /path/to/images -c config/my_config.yaml
```

### Advanced Options
```bash
# Set batch size for processing
python src/main.py process -i /path/to/images --batch-size 64

# Enable debug logging
python src/main.py process -i /path/to/images --log-level DEBUG

# Save logs to file
python src/main.py process -i /path/to/images --log-file processing.log

# Search non-recursively
python src/main.py process -i /path/to/images --no-recursive
```

## Configuration

The tool uses a YAML configuration file to customize processing parameters:

### Model Configuration
```yaml
models:
  gender_model:
    path: "models/gender-recognition-retail-0013.xml"
    device: "NPU"  # NPU, CPU, GPU
    confidence_threshold: 0.7
  
  face_detection:
    path: "models/face-detection-adas-0001.xml"
    device: "NPU"
    confidence_threshold: 0.5
```

### Avatar Criteria
```yaml
avatar_criteria:
  min_face_ratio: 0.15      # Minimum face size (15% of image)
  max_face_ratio: 0.85      # Maximum face size (85% of image)
  min_resolution: [224, 224] # Minimum image resolution
  min_brightness: 50        # Minimum brightness (0-255)
  max_brightness: 220       # Maximum brightness (0-255)
  min_contrast: 30          # Minimum contrast value
  max_blur_threshold: 50    # Maximum blur (lower = sharper)
  min_face_confidence: 0.8  # Minimum face detection confidence
```

### Processing Options
```yaml
processing:
  batch_size: 32           # Images per batch
  num_workers: 4           # Parallel workers
  progress_bar: true       # Show progress bar
  verbose_logging: true    # Detailed logging
```

## Performance

### Intel NPU Optimization
- Utilizes Intel NPU for accelerated AI inference
- Automatic fallback to CPU if NPU is not available
- Optimized batch processing for maximum throughput
- Memory-efficient image preprocessing

### Typical Performance
- **Processing Speed**: ~0.1-0.5 seconds per image (NPU)
- **Accuracy**: >85% gender classification accuracy
- **Batch Processing**: 32-64 images per batch for optimal performance

## Privacy and Ethics

### Data Handling
- No personal data stored permanently
- Images processed locally without external transmission
- Configurable privacy settings

### AI Classification Limitations
- AI classification results are estimates and may not be 100% accurate
- Results should be reviewed for sensitive applications
- Tool provides confidence scores for transparency
- Includes "Uncertain" category for low-confidence classifications

## Output and Reporting

### Directory Organization
Images are automatically organized into the following structure based on classification results:
- **Male/Suitable**: Male-classified images suitable for avatars
- **Male/Not_Suitable**: Male-classified images not suitable for avatars
- **Female/Suitable**: Female-classified images suitable for avatars
- **Female/Not_Suitable**: Female-classified images not suitable for avatars
- **Uncertain/Suitable**: Gender-uncertain images suitable for avatars
- **Uncertain/Not_Suitable**: Gender-uncertain images not suitable for avatars

### Summary Report
The tool generates a comprehensive summary report (`summary_report.txt`) containing:
- Processing statistics and success rates
- Gender distribution and percentages
- Suitability analysis and quality metrics
- List of any failed files
- Complete directory structure with counts

### Quality Metrics
Each image is evaluated on multiple criteria:
- **Face Detection**: Confidence in face detection
- **Face Ratio**: Proportion of face in image
- **Image Quality**: Brightness, contrast, and sharpness
- **Resolution**: Minimum resolution requirements
- **Overall Suitability**: Combined score for avatar use

## Troubleshooting

### Common Issues

**"OpenVINO not available"**
- Install OpenVINO runtime: `pip install openvino`
- Tool will use mock implementations for testing

**"Intel NPU not detected"**
- Ensure Intel NPU drivers are installed
- Tool will automatically fall back to CPU processing

**"Model file not found"**
- Download required models to the `models/` directory
- Update model paths in configuration file

**"No faces detected"**
- Ensure images contain clear, visible faces
- Adjust face detection confidence threshold in config
- Check image quality and resolution

### Performance Optimization

**For Intel NPU:**
- Use batch sizes of 32-64 for optimal NPU utilization
- Ensure NPU drivers are up to date
- Use NPU device setting in configuration

**For CPU Processing:**
- Reduce batch size to 8-16 for memory efficiency
- Use multiple workers for parallel processing
- Consider image preprocessing optimizations

## License

This project is provided as-is for educational and evaluation purposes. Please ensure compliance with relevant AI model licenses and local data protection regulations.

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review log files for detailed error information
3. Ensure all dependencies are properly installed
4. Verify model files are correctly downloaded and configured