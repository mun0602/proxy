"""
Model Manager for handling OpenVINO models on Intel NPU
"""
import logging
import numpy as np
from pathlib import Path
from typing import Dict, Tuple, Optional, Any
import cv2

try:
    from openvino.runtime import Core, Model, CompiledModel
    from openvino.preprocess import PrePostProcessor, ResizeAlgorithm
    from openvino.runtime import Layout, Type
    OPENVINO_AVAILABLE = True
except ImportError:
    OPENVINO_AVAILABLE = False
    logging.warning("OpenVINO not available. Falling back to mock implementations.")

class ModelManager:
    """Manages loading and inference of OpenVINO models for Intel NPU"""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.core = None
        self.models = {}
        self.compiled_models = {}
        
        if OPENVINO_AVAILABLE:
            self.core = Core()
            self._log_available_devices()
        else:
            logging.warning("OpenVINO not available. Using mock model manager.")
    
    def _log_available_devices(self):
        """Log available OpenVINO devices"""
        if self.core:
            available_devices = self.core.available_devices
            logging.info(f"Available OpenVINO devices: {available_devices}")
            
            # Check for NPU availability
            if "NPU" in available_devices:
                logging.info("Intel NPU detected and available")
            else:
                logging.warning("Intel NPU not detected. Falling back to CPU.")
    
    def load_model(self, model_name: str, model_path: str, device: str = "NPU") -> bool:
        """
        Load an OpenVINO model
        
        Args:
            model_name: Name to identify the model
            model_path: Path to the .xml model file
            device: Target device (NPU, CPU, GPU)
            
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            if not OPENVINO_AVAILABLE:
                # Mock implementation for testing
                self.models[model_name] = {"mock": True, "device": device}
                self.compiled_models[model_name] = {"mock": True}
                logging.info(f"Mock model '{model_name}' loaded for device '{device}'")
                return True
            
            model_path = Path(model_path)
            if not model_path.exists():
                logging.error(f"Model file not found: {model_path}")
                return False
            
            # Load model
            model = self.core.read_model(str(model_path))
            
            # Check device availability and fallback if needed
            available_devices = self.core.available_devices
            if device not in available_devices:
                logging.warning(f"Device '{device}' not available. Falling back to CPU.")
                device = "CPU"
            
            # Compile model for target device
            compiled_model = self.core.compile_model(model, device)
            
            self.models[model_name] = model
            self.compiled_models[model_name] = compiled_model
            
            logging.info(f"Successfully loaded model '{model_name}' on device '{device}'")
            return True
            
        except Exception as e:
            logging.error(f"Failed to load model '{model_name}': {str(e)}")
            return False
    
    def preprocess_image(self, image: np.ndarray, target_size: Tuple[int, int]) -> np.ndarray:
        """
        Preprocess image for model inference
        
        Args:
            image: Input image as numpy array
            target_size: Target size (width, height)
            
        Returns:
            Preprocessed image
        """
        # Resize image
        resized = cv2.resize(image, target_size)
        
        # Convert BGR to RGB if needed
        if len(resized.shape) == 3 and resized.shape[2] == 3:
            resized = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
        
        # Normalize to [0, 1]
        normalized = resized.astype(np.float32) / 255.0
        
        # Apply standard normalization if specified in config
        if "normalization" in self.config.get("image_processing", {}):
            norm_config = self.config["image_processing"]["normalization"]
            mean = np.array(norm_config["mean"])
            std = np.array(norm_config["std"])
            normalized = (normalized - mean) / std
        
        # Add batch dimension and transpose to NCHW if needed
        if len(normalized.shape) == 3:
            normalized = np.transpose(normalized, (2, 0, 1))  # HWC to CHW
        normalized = np.expand_dims(normalized, axis=0)  # Add batch dimension
        
        return normalized
    
    def run_inference(self, model_name: str, input_data: np.ndarray) -> Optional[np.ndarray]:
        """
        Run inference on a loaded model
        
        Args:
            model_name: Name of the model to use
            input_data: Preprocessed input data
            
        Returns:
            Model output or None if failed
        """
        try:
            if model_name not in self.compiled_models:
                logging.error(f"Model '{model_name}' not loaded")
                return None
            
            if not OPENVINO_AVAILABLE:
                # Mock inference for testing
                if model_name == "gender_model":
                    # Mock gender classification output [female_prob, male_prob]
                    return np.array([[0.3, 0.7]])  # Example: 70% male
                elif model_name == "face_detection":
                    # Mock face detection output [x1, y1, x2, y2, confidence]
                    return np.array([[0.2, 0.2, 0.8, 0.8, 0.95]])
                else:
                    # Generic mock output
                    return np.random.random((1, 4))
            
            compiled_model = self.compiled_models[model_name]
            
            # Get input layer name
            input_layer = compiled_model.input(0)
            
            # Run inference
            result = compiled_model([input_data])[compiled_model.output(0)]
            
            return result
            
        except Exception as e:
            logging.error(f"Inference failed for model '{model_name}': {str(e)}")
            return None
    
    def detect_faces(self, image: np.ndarray) -> list:
        """
        Detect faces in image using face detection model
        
        Args:
            image: Input image
            
        Returns:
            List of face bounding boxes [(x1, y1, x2, y2, confidence), ...]
        """
        try:
            # Preprocess image for face detection
            target_size = (300, 300)  # Common size for face detection models
            preprocessed = self.preprocess_image(image, target_size)
            
            # Run inference
            result = self.run_inference("face_detection", preprocessed)
            
            if result is None:
                return []
            
            faces = []
            height, width = image.shape[:2]
            
            # Parse detection results (assuming SSD-style output)
            for detection in result[0][0]:
                confidence = detection[2]
                if confidence > self.config["models"]["face_detection"]["confidence_threshold"]:
                    x1 = int(detection[3] * width)
                    y1 = int(detection[4] * height)
                    x2 = int(detection[5] * width)
                    y2 = int(detection[6] * height)
                    faces.append((x1, y1, x2, y2, confidence))
            
            return faces
            
        except Exception as e:
            logging.error(f"Face detection failed: {str(e)}")
            return []
    
    def classify_gender(self, face_image: np.ndarray) -> Tuple[str, float]:
        """
        Classify gender of face image
        
        Args:
            face_image: Cropped face image
            
        Returns:
            Tuple of (gender, confidence) where gender is 'Male', 'Female', or 'Uncertain'
        """
        try:
            # Preprocess face image
            target_size = tuple(self.config["image_processing"]["target_size"])
            preprocessed = self.preprocess_image(face_image, target_size)
            
            # Run inference
            result = self.run_inference("gender_model", preprocessed)
            
            if result is None:
                return "Uncertain", 0.0
            
            # Parse gender classification result
            # Assuming output is [female_prob, male_prob]
            female_prob = result[0][0]
            male_prob = result[0][1]
            
            confidence_threshold = self.config["models"]["gender_model"]["confidence_threshold"]
            
            if male_prob > female_prob and male_prob > confidence_threshold:
                return "Male", float(male_prob)
            elif female_prob > male_prob and female_prob > confidence_threshold:
                return "Female", float(female_prob)
            else:
                return "Uncertain", max(float(male_prob), float(female_prob))
                
        except Exception as e:
            logging.error(f"Gender classification failed: {str(e)}")
            return "Uncertain", 0.0
    
    def assess_face_quality(self, face_image: np.ndarray) -> float:
        """
        Assess quality of face image for avatar use
        
        Args:
            face_image: Cropped face image
            
        Returns:
            Quality score (0.0 to 1.0)
        """
        try:
            # Basic quality metrics using computer vision
            
            # 1. Check image sharpness (Laplacian variance)
            gray = cv2.cvtColor(face_image, cv2.COLOR_RGB2GRAY) if len(face_image.shape) == 3 else face_image
            laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
            sharpness_score = min(laplacian_var / 100.0, 1.0)  # Normalize
            
            # 2. Check brightness
            brightness = np.mean(gray)
            brightness_score = 1.0 - abs(brightness - 127.5) / 127.5  # Ideal brightness around 127.5
            
            # 3. Check contrast
            contrast = np.std(gray)
            contrast_score = min(contrast / 50.0, 1.0)  # Normalize
            
            # Weighted average of quality metrics
            quality_score = (sharpness_score * 0.4 + brightness_score * 0.3 + contrast_score * 0.3)
            
            return max(0.0, min(1.0, quality_score))
            
        except Exception as e:
            logging.error(f"Face quality assessment failed: {str(e)}")
            return 0.0
    
    def load_all_models(self) -> bool:
        """
        Load all models specified in configuration
        
        Returns:
            bool: True if all models loaded successfully
        """
        success = True
        
        for model_name, model_config in self.config.get("models", {}).items():
            if "path" in model_config:
                device = model_config.get("device", "NPU")
                if not self.load_model(model_name, model_config["path"], device):
                    success = False
        
        return success