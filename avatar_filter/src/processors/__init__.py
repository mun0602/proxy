"""
Image and classification processors
"""

from .image_processor import ImageProcessor
from .classification_engine import ClassificationEngine, ClassificationResult

__all__ = ['ImageProcessor', 'ClassificationEngine', 'ClassificationResult']