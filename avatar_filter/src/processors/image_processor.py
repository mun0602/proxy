"""
Image Processor for handling image loading, preprocessing, and analysis
"""
import logging
import numpy as np
from pathlib import Path
from typing import List, Tuple, Optional, Dict, Any
import cv2
from PIL import Image, ImageEnhance
import os

class ImageProcessor:
    """Handles image loading, preprocessing, and basic analysis"""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.supported_formats = config.get("image_processing", {}).get(
            "supported_formats", [".jpg", ".jpeg", ".png", ".webp"]
        )
    
    def load_image(self, image_path: str) -> Optional[np.ndarray]:
        """
        Load image from file
        
        Args:
            image_path: Path to image file
            
        Returns:
            Image as numpy array or None if failed
        """
        try:
            image_path = Path(image_path)
            
            if not image_path.exists():
                logging.error(f"Image file not found: {image_path}")
                return None
            
            if image_path.suffix.lower() not in self.supported_formats:
                logging.warning(f"Unsupported image format: {image_path.suffix}")
                return None
            
            # Load using PIL for better format support
            pil_image = Image.open(image_path)
            
            # Convert to RGB if needed
            if pil_image.mode != 'RGB':
                pil_image = pil_image.convert('RGB')
            
            # Convert to numpy array
            image = np.array(pil_image)
            
            return image
            
        except Exception as e:
            logging.error(f"Failed to load image '{image_path}': {str(e)}")
            return None
    
    def save_image(self, image: np.ndarray, output_path: str) -> bool:
        """
        Save image to file
        
        Args:
            image: Image as numpy array
            output_path: Output file path
            
        Returns:
            bool: True if successful
        """
        try:
            output_path = Path(output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            
            # Convert numpy array to PIL Image
            if image.dtype != np.uint8:
                image = (image * 255).astype(np.uint8)
            
            pil_image = Image.fromarray(image)
            pil_image.save(output_path)
            
            return True
            
        except Exception as e:
            logging.error(f"Failed to save image to '{output_path}': {str(e)}")
            return False
    
    def get_image_info(self, image: np.ndarray) -> Dict[str, Any]:
        """
        Get basic information about the image
        
        Args:
            image: Image as numpy array
            
        Returns:
            Dictionary with image information
        """
        height, width = image.shape[:2]
        channels = image.shape[2] if len(image.shape) == 3 else 1
        
        # Calculate basic statistics
        if len(image.shape) == 3:
            gray = cv2.cvtColor(image, cv2.COLOR_RGB2GRAY)
        else:
            gray = image
        
        brightness = np.mean(gray)
        contrast = np.std(gray)
        
        # Estimate sharpness using Laplacian variance
        sharpness = cv2.Laplacian(gray, cv2.CV_64F).var()
        
        return {
            "width": width,
            "height": height,
            "channels": channels,
            "resolution": (width, height),
            "brightness": float(brightness),
            "contrast": float(contrast),
            "sharpness": float(sharpness),
            "aspect_ratio": width / height
        }
    
    def validate_image_quality(self, image: np.ndarray) -> Tuple[bool, List[str]]:
        """
        Validate image quality against avatar criteria
        
        Args:
            image: Image as numpy array
            
        Returns:
            Tuple of (is_valid, list_of_issues)
        """
        issues = []
        criteria = self.config.get("avatar_criteria", {})
        
        info = self.get_image_info(image)
        
        # Check minimum resolution
        min_res = criteria.get("min_resolution", [224, 224])
        if info["width"] < min_res[0] or info["height"] < min_res[1]:
            issues.append(f"Resolution too low: {info['resolution']} < {min_res}")
        
        # Check brightness
        min_brightness = criteria.get("min_brightness", 50)
        max_brightness = criteria.get("max_brightness", 220)
        if info["brightness"] < min_brightness:
            issues.append(f"Image too dark: brightness {info['brightness']:.1f} < {min_brightness}")
        elif info["brightness"] > max_brightness:
            issues.append(f"Image too bright: brightness {info['brightness']:.1f} > {max_brightness}")
        
        # Check contrast
        min_contrast = criteria.get("min_contrast", 30)
        if info["contrast"] < min_contrast:
            issues.append(f"Low contrast: {info['contrast']:.1f} < {min_contrast}")
        
        # Check sharpness (blur detection)
        max_blur = criteria.get("max_blur_threshold", 50)
        if info["sharpness"] < max_blur:
            issues.append(f"Image too blurry: sharpness {info['sharpness']:.1f} < {max_blur}")
        
        return len(issues) == 0, issues
    
    def calculate_face_ratio(self, image: np.ndarray, face_bbox: Tuple[int, int, int, int]) -> float:
        """
        Calculate the ratio of face area to total image area
        
        Args:
            image: Original image
            face_bbox: Face bounding box (x1, y1, x2, y2)
            
        Returns:
            Face ratio (0.0 to 1.0)
        """
        image_height, image_width = image.shape[:2]
        image_area = image_width * image_height
        
        x1, y1, x2, y2 = face_bbox
        face_width = max(0, x2 - x1)
        face_height = max(0, y2 - y1)
        face_area = face_width * face_height
        
        return face_area / image_area if image_area > 0 else 0.0
    
    def crop_face(self, image: np.ndarray, face_bbox: Tuple[int, int, int, int], padding: float = 0.2) -> np.ndarray:
        """
        Crop face from image with optional padding
        
        Args:
            image: Original image
            face_bbox: Face bounding box (x1, y1, x2, y2)
            padding: Padding ratio around face (e.g., 0.2 for 20% padding)
            
        Returns:
            Cropped face image
        """
        height, width = image.shape[:2]
        x1, y1, x2, y2 = face_bbox
        
        # Calculate face dimensions
        face_width = x2 - x1
        face_height = y2 - y1
        
        # Add padding
        pad_x = int(face_width * padding)
        pad_y = int(face_height * padding)
        
        # Calculate new bounding box with padding
        new_x1 = max(0, x1 - pad_x)
        new_y1 = max(0, y1 - pad_y)
        new_x2 = min(width, x2 + pad_x)
        new_y2 = min(height, y2 + pad_y)
        
        # Crop the image
        cropped = image[new_y1:new_y2, new_x1:new_x2]
        
        return cropped
    
    def enhance_image(self, image: np.ndarray) -> np.ndarray:
        """
        Apply basic image enhancement for better processing
        
        Args:
            image: Input image
            
        Returns:
            Enhanced image
        """
        try:
            # Convert to PIL for easier enhancement
            pil_image = Image.fromarray(image)
            
            # Apply mild enhancements
            enhancer = ImageEnhance.Contrast(pil_image)
            enhanced = enhancer.enhance(1.1)  # Slight contrast boost
            
            enhancer = ImageEnhance.Sharpness(enhanced)
            enhanced = enhancer.enhance(1.1)  # Slight sharpness boost
            
            enhancer = ImageEnhance.Color(enhanced)
            enhanced = enhancer.enhance(1.05)  # Very slight color boost
            
            return np.array(enhanced)
            
        except Exception as e:
            logging.warning(f"Image enhancement failed: {str(e)}")
            return image
    
    def find_images_in_directory(self, directory_path: str, recursive: bool = True) -> List[str]:
        """
        Find all supported image files in a directory
        
        Args:
            directory_path: Path to directory
            recursive: Whether to search recursively
            
        Returns:
            List of image file paths
        """
        image_files = []
        directory_path = Path(directory_path)
        
        if not directory_path.exists() or not directory_path.is_dir():
            logging.error(f"Directory not found: {directory_path}")
            return image_files
        
        try:
            if recursive:
                pattern = "**/*"
                files = directory_path.glob(pattern)
            else:
                files = directory_path.iterdir()
            
            for file_path in files:
                if file_path.is_file() and file_path.suffix.lower() in self.supported_formats:
                    image_files.append(str(file_path))
            
            logging.info(f"Found {len(image_files)} image files in {directory_path}")
            return sorted(image_files)
            
        except Exception as e:
            logging.error(f"Error searching directory '{directory_path}': {str(e)}")
            return image_files
    
    def batch_process_images(self, image_paths: List[str], process_func, **kwargs) -> List[Any]:
        """
        Process a batch of images with a given function
        
        Args:
            image_paths: List of image file paths
            process_func: Function to apply to each image
            **kwargs: Additional arguments for process_func
            
        Returns:
            List of processing results
        """
        results = []
        
        for image_path in image_paths:
            try:
                image = self.load_image(image_path)
                if image is not None:
                    result = process_func(image, **kwargs)
                    results.append((image_path, result))
                else:
                    results.append((image_path, None))
                    
            except Exception as e:
                logging.error(f"Error processing image '{image_path}': {str(e)}")
                results.append((image_path, None))
        
        return results
    
    def resize_image(self, image: np.ndarray, target_size: Tuple[int, int], maintain_aspect: bool = False) -> np.ndarray:
        """
        Resize image to target size
        
        Args:
            image: Input image
            target_size: Target size (width, height)
            maintain_aspect: Whether to maintain aspect ratio
            
        Returns:
            Resized image
        """
        if maintain_aspect:
            height, width = image.shape[:2]
            target_width, target_height = target_size
            
            # Calculate scaling factor
            scale = min(target_width / width, target_height / height)
            new_width = int(width * scale)
            new_height = int(height * scale)
            
            # Resize
            resized = cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_LANCZOS4)
            
            # Add padding if needed
            if new_width != target_width or new_height != target_height:
                # Create canvas
                canvas = np.zeros((target_height, target_width, image.shape[2]), dtype=image.dtype)
                
                # Center the image
                y_offset = (target_height - new_height) // 2
                x_offset = (target_width - new_width) // 2
                
                canvas[y_offset:y_offset + new_height, x_offset:x_offset + new_width] = resized
                resized = canvas
        else:
            resized = cv2.resize(image, target_size, interpolation=cv2.INTER_LANCZOS4)
        
        return resized