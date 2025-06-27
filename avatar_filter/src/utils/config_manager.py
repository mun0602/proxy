"""
Configuration management utilities
"""
import logging
import yaml
from pathlib import Path
from typing import Dict, Any, Optional

class ConfigManager:
    """Manages configuration loading and validation"""
    
    def __init__(self, config_path: str = None):
        self.config_path = config_path
        self.config = {}
        
        if config_path:
            self.load_config(config_path)
    
    def load_config(self, config_path: str) -> bool:
        """
        Load configuration from YAML file
        
        Args:
            config_path: Path to configuration file
            
        Returns:
            bool: True if successful
        """
        try:
            config_path = Path(config_path)
            
            if not config_path.exists():
                logging.error(f"Configuration file not found: {config_path}")
                return False
            
            with open(config_path, 'r', encoding='utf-8') as f:
                self.config = yaml.safe_load(f)
            
            logging.info(f"Configuration loaded from: {config_path}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to load configuration: {str(e)}")
            return False
    
    def get(self, key: str, default: Any = None) -> Any:
        """
        Get configuration value by key
        
        Args:
            key: Configuration key (supports dot notation)
            default: Default value if key not found
            
        Returns:
            Configuration value or default
        """
        keys = key.split('.')
        value = self.config
        
        for k in keys:
            if isinstance(value, dict) and k in value:
                value = value[k]
            else:
                return default
        
        return value
    
    def set(self, key: str, value: Any) -> None:
        """
        Set configuration value
        
        Args:
            key: Configuration key (supports dot notation)
            value: Value to set
        """
        keys = key.split('.')
        config = self.config
        
        for k in keys[:-1]:
            if k not in config:
                config[k] = {}
            config = config[k]
        
        config[keys[-1]] = value
    
    def validate_config(self) -> tuple[bool, list[str]]:
        """
        Validate configuration completeness and correctness
        
        Returns:
            Tuple of (is_valid, list_of_issues)
        """
        issues = []
        
        # Check required sections
        required_sections = ['models', 'image_processing', 'avatar_criteria', 'output']
        for section in required_sections:
            if section not in self.config:
                issues.append(f"Missing required section: {section}")
        
        # Validate models section
        if 'models' in self.config:
            models_config = self.config['models']
            required_models = ['gender_model', 'face_detection']
            
            for model in required_models:
                if model not in models_config:
                    issues.append(f"Missing model configuration: {model}")
                else:
                    model_config = models_config[model]
                    if 'path' not in model_config:
                        issues.append(f"Missing path for model: {model}")
                    if 'device' not in model_config:
                        issues.append(f"Missing device for model: {model}")
        
        # Validate avatar criteria
        if 'avatar_criteria' in self.config:
            criteria = self.config['avatar_criteria']
            required_criteria = ['min_face_ratio', 'max_face_ratio', 'min_resolution']
            
            for criterion in required_criteria:
                if criterion not in criteria:
                    issues.append(f"Missing avatar criterion: {criterion}")
        
        # Validate output configuration
        if 'output' in self.config:
            output_config = self.config['output']
            if 'base_directory' not in output_config:
                issues.append("Missing output base_directory")
            if 'structure' not in output_config:
                issues.append("Missing output structure")
        
        return len(issues) == 0, issues
    
    def get_model_config(self, model_name: str) -> Optional[Dict[str, Any]]:
        """
        Get configuration for a specific model
        
        Args:
            model_name: Name of the model
            
        Returns:
            Model configuration or None
        """
        return self.get(f'models.{model_name}')
    
    def save_config(self, output_path: str = None) -> bool:
        """
        Save current configuration to file
        
        Args:
            output_path: Path to save configuration (uses original path if None)
            
        Returns:
            bool: True if successful
        """
        try:
            if output_path is None:
                output_path = self.config_path
            
            if output_path is None:
                logging.error("No output path specified for saving configuration")
                return False
            
            output_path = Path(output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            
            with open(output_path, 'w', encoding='utf-8') as f:
                yaml.dump(self.config, f, default_flow_style=False, indent=2)
            
            logging.info(f"Configuration saved to: {output_path}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to save configuration: {str(e)}")
            return False

def setup_logging(level: str = "INFO", log_file: str = None) -> None:
    """
    Setup logging configuration
    
    Args:
        level: Logging level
        log_file: Optional log file path
    """
    log_format = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    
    # Configure logging
    logging.basicConfig(
        level=getattr(logging, level.upper()),
        format=log_format,
        handlers=[]
    )
    
    # Console handler
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(logging.Formatter(log_format))
    logging.getLogger().addHandler(console_handler)
    
    # File handler (optional)
    if log_file:
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(logging.Formatter(log_format))
        logging.getLogger().addHandler(file_handler)

def create_default_config() -> Dict[str, Any]:
    """
    Create default configuration
    
    Returns:
        Default configuration dictionary
    """
    return {
        "models": {
            "gender_model": {
                "path": "models/gender-recognition-retail-0013.xml",
                "device": "NPU",
                "confidence_threshold": 0.7
            },
            "face_detection": {
                "path": "models/face-detection-adas-0001.xml", 
                "device": "NPU",
                "confidence_threshold": 0.5
            },
            "face_quality": {
                "path": "models/face-reidentification-retail-0095.xml",
                "device": "NPU", 
                "quality_threshold": 0.6
            }
        },
        "image_processing": {
            "supported_formats": [".jpg", ".jpeg", ".png", ".webp"],
            "target_size": [224, 224],
            "normalization": {
                "mean": [0.485, 0.456, 0.406],
                "std": [0.229, 0.224, 0.225]
            }
        },
        "avatar_criteria": {
            "min_face_ratio": 0.15,
            "max_face_ratio": 0.85,
            "min_resolution": [224, 224],
            "min_brightness": 50,
            "max_brightness": 220,
            "min_contrast": 30,
            "max_blur_threshold": 50,
            "min_face_confidence": 0.8,
            "max_head_pose_angle": 30
        },
        "output": {
            "base_directory": "output",
            "structure": [
                "Male/Suitable",
                "Male/Not_Suitable",
                "Female/Suitable", 
                "Female/Not_Suitable",
                "Uncertain/Suitable",
                "Uncertain/Not_Suitable"
            ]
        },
        "processing": {
            "batch_size": 32,
            "num_workers": 4,
            "progress_bar": True,
            "verbose_logging": True
        },
        "error_handling": {
            "continue_on_error": True,
            "log_errors": True,
            "max_retries": 3
        }
    }