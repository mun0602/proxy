"""
Classification Engine for gender classification and avatar suitability assessment
"""
import logging
import numpy as np
from typing import Dict, Tuple, List, Any, Optional
from dataclasses import dataclass

@dataclass
class ClassificationResult:
    """Container for classification results"""
    gender: str  # "Male", "Female", or "Uncertain"
    gender_confidence: float
    is_suitable: bool
    suitability_score: float
    face_ratio: float
    quality_issues: List[str]
    face_bbox: Optional[Tuple[int, int, int, int]] = None

class ClassificationEngine:
    """Engine for gender classification and avatar suitability assessment"""
    
    def __init__(self, model_manager, image_processor, config: Dict[str, Any]):
        self.model_manager = model_manager
        self.image_processor = image_processor
        self.config = config
        self.avatar_criteria = config.get("avatar_criteria", {})
    
    def classify_image(self, image: np.ndarray, image_path: str = "") -> ClassificationResult:
        """
        Perform complete classification of an image
        
        Args:
            image: Input image as numpy array
            image_path: Optional path for logging
            
        Returns:
            ClassificationResult with all analysis results
        """
        try:
            # Initialize result with defaults
            result = ClassificationResult(
                gender="Uncertain",
                gender_confidence=0.0,
                is_suitable=False,
                suitability_score=0.0,
                face_ratio=0.0,
                quality_issues=[]
            )
            
            # Step 1: Validate basic image quality
            is_valid, quality_issues = self.image_processor.validate_image_quality(image)
            result.quality_issues = quality_issues
            
            if not is_valid:
                logging.info(f"Image quality validation failed for {image_path}: {quality_issues}")
                return result
            
            # Step 2: Detect faces
            faces = self.model_manager.detect_faces(image)
            
            if not faces:
                result.quality_issues.append("No faces detected")
                logging.info(f"No faces detected in {image_path}")
                return result
            
            # Use the largest/most confident face
            best_face = max(faces, key=lambda f: f[4])  # Sort by confidence
            face_bbox = best_face[:4]
            face_confidence = best_face[4]
            result.face_bbox = face_bbox
            
            # Check face detection confidence
            min_face_conf = self.avatar_criteria.get("min_face_confidence", 0.8)
            if face_confidence < min_face_conf:
                result.quality_issues.append(f"Low face detection confidence: {face_confidence:.2f}")
            
            # Step 3: Calculate face ratio
            result.face_ratio = self.image_processor.calculate_face_ratio(image, face_bbox)
            
            # Validate face ratio
            min_face_ratio = self.avatar_criteria.get("min_face_ratio", 0.15)
            max_face_ratio = self.avatar_criteria.get("max_face_ratio", 0.85)
            
            if result.face_ratio < min_face_ratio:
                result.quality_issues.append(f"Face too small: {result.face_ratio:.2f} < {min_face_ratio}")
            elif result.face_ratio > max_face_ratio:
                result.quality_issues.append(f"Face too large: {result.face_ratio:.2f} > {max_face_ratio}")
            
            # Step 4: Crop face for detailed analysis
            face_image = self.image_processor.crop_face(image, face_bbox)
            
            # Step 5: Assess face quality
            face_quality_score = self.model_manager.assess_face_quality(face_image)
            quality_threshold = self.config.get("models", {}).get("face_quality", {}).get("quality_threshold", 0.6)
            
            if face_quality_score < quality_threshold:
                result.quality_issues.append(f"Poor face quality: {face_quality_score:.2f} < {quality_threshold}")
            
            # Step 6: Gender classification
            gender, gender_confidence = self.model_manager.classify_gender(face_image)
            result.gender = gender
            result.gender_confidence = gender_confidence
            
            # Step 7: Calculate overall suitability
            result.suitability_score = self._calculate_suitability_score(
                face_quality_score, face_confidence, result.face_ratio, len(result.quality_issues)
            )
            
            # Determine if suitable (no critical issues)
            result.is_suitable = len(result.quality_issues) == 0 and result.suitability_score > 0.5
            
            logging.debug(f"Classification complete for {image_path}: "
                         f"Gender={result.gender}({result.gender_confidence:.2f}), "
                         f"Suitable={result.is_suitable}({result.suitability_score:.2f})")
            
            return result
            
        except Exception as e:
            logging.error(f"Classification failed for {image_path}: {str(e)}")
            return ClassificationResult(
                gender="Uncertain",
                gender_confidence=0.0,
                is_suitable=False,
                suitability_score=0.0,
                face_ratio=0.0,
                quality_issues=[f"Classification error: {str(e)}"]
            )
    
    def _calculate_suitability_score(self, face_quality: float, face_confidence: float, 
                                   face_ratio: float, num_issues: int) -> float:
        """
        Calculate overall suitability score
        
        Args:
            face_quality: Face quality score (0-1)
            face_confidence: Face detection confidence (0-1)
            face_ratio: Face ratio in image (0-1)
            num_issues: Number of quality issues
            
        Returns:
            Suitability score (0-1)
        """
        # Base score from face quality and detection confidence
        base_score = (face_quality * 0.5 + face_confidence * 0.3)
        
        # Face ratio score (optimal range)
        min_ratio = self.avatar_criteria.get("min_face_ratio", 0.15)
        max_ratio = self.avatar_criteria.get("max_face_ratio", 0.85)
        optimal_min = 0.25
        optimal_max = 0.65
        
        if optimal_min <= face_ratio <= optimal_max:
            ratio_score = 1.0
        elif min_ratio <= face_ratio <= max_ratio:
            # Gradual falloff outside optimal range
            if face_ratio < optimal_min:
                ratio_score = (face_ratio - min_ratio) / (optimal_min - min_ratio)
            else:
                ratio_score = (max_ratio - face_ratio) / (max_ratio - optimal_max)
        else:
            ratio_score = 0.0
        
        base_score += ratio_score * 0.2
        
        # Penalty for issues
        issue_penalty = min(num_issues * 0.2, 0.8)
        
        final_score = max(0.0, base_score - issue_penalty)
        
        return final_score
    
    def batch_classify(self, image_paths: List[str]) -> List[Tuple[str, ClassificationResult]]:
        """
        Classify a batch of images
        
        Args:
            image_paths: List of image file paths
            
        Returns:
            List of tuples (image_path, ClassificationResult)
        """
        results = []
        
        for image_path in image_paths:
            try:
                image = self.image_processor.load_image(image_path)
                if image is not None:
                    result = self.classify_image(image, image_path)
                    results.append((image_path, result))
                else:
                    # Create failed result
                    failed_result = ClassificationResult(
                        gender="Uncertain",
                        gender_confidence=0.0,
                        is_suitable=False,
                        suitability_score=0.0,
                        face_ratio=0.0,
                        quality_issues=["Failed to load image"]
                    )
                    results.append((image_path, failed_result))
                    
            except Exception as e:
                logging.error(f"Error processing {image_path}: {str(e)}")
                failed_result = ClassificationResult(
                    gender="Uncertain",
                    gender_confidence=0.0,
                    is_suitable=False,
                    suitability_score=0.0,
                    face_ratio=0.0,
                    quality_issues=[f"Processing error: {str(e)}"]
                )
                results.append((image_path, failed_result))
        
        return results
    
    def get_classification_summary(self, results: List[Tuple[str, ClassificationResult]]) -> Dict[str, Any]:
        """
        Generate summary statistics from classification results
        
        Args:
            results: List of classification results
            
        Returns:
            Summary statistics dictionary
        """
        total_images = len(results)
        
        if total_images == 0:
            return {"total_images": 0}
        
        # Count by gender
        gender_counts = {"Male": 0, "Female": 0, "Uncertain": 0}
        suitable_counts = {"Male": 0, "Female": 0, "Uncertain": 0}
        
        # Quality metrics
        total_suitable = 0
        confidence_scores = []
        suitability_scores = []
        face_ratios = []
        
        for image_path, result in results:
            gender_counts[result.gender] += 1
            confidence_scores.append(result.gender_confidence)
            suitability_scores.append(result.suitability_score)
            face_ratios.append(result.face_ratio)
            
            if result.is_suitable:
                total_suitable += 1
                suitable_counts[result.gender] += 1
        
        # Calculate statistics
        avg_confidence = np.mean(confidence_scores) if confidence_scores else 0.0
        avg_suitability = np.mean(suitability_scores) if suitability_scores else 0.0
        avg_face_ratio = np.mean(face_ratios) if face_ratios else 0.0
        
        summary = {
            "total_images": total_images,
            "total_suitable": total_suitable,
            "suitability_rate": total_suitable / total_images if total_images > 0 else 0.0,
            "gender_distribution": {
                "Male": gender_counts["Male"],
                "Female": gender_counts["Female"],
                "Uncertain": gender_counts["Uncertain"]
            },
            "suitable_by_gender": {
                "Male": suitable_counts["Male"],
                "Female": suitable_counts["Female"], 
                "Uncertain": suitable_counts["Uncertain"]
            },
            "average_metrics": {
                "gender_confidence": avg_confidence,
                "suitability_score": avg_suitability,
                "face_ratio": avg_face_ratio
            },
            "gender_percentages": {
                "Male": (gender_counts["Male"] / total_images * 100) if total_images > 0 else 0.0,
                "Female": (gender_counts["Female"] / total_images * 100) if total_images > 0 else 0.0,
                "Uncertain": (gender_counts["Uncertain"] / total_images * 100) if total_images > 0 else 0.0
            }
        }
        
        return summary
    
    def validate_classification_accuracy(self, results: List[Tuple[str, ClassificationResult]], 
                                       ground_truth: Dict[str, str]) -> Dict[str, float]:
        """
        Validate classification accuracy against ground truth
        
        Args:
            results: Classification results
            ground_truth: Dictionary mapping image paths to correct genders
            
        Returns:
            Accuracy metrics
        """
        if not ground_truth:
            return {"accuracy": 0.0, "total_evaluated": 0}
        
        correct_predictions = 0
        total_evaluated = 0
        gender_accuracy = {"Male": {"correct": 0, "total": 0}, 
                          "Female": {"correct": 0, "total": 0}}
        
        for image_path, result in results:
            if image_path in ground_truth:
                true_gender = ground_truth[image_path]
                predicted_gender = result.gender
                
                total_evaluated += 1
                
                if true_gender in gender_accuracy:
                    gender_accuracy[true_gender]["total"] += 1
                
                if true_gender == predicted_gender:
                    correct_predictions += 1
                    if true_gender in gender_accuracy:
                        gender_accuracy[true_gender]["correct"] += 1
        
        overall_accuracy = correct_predictions / total_evaluated if total_evaluated > 0 else 0.0
        
        metrics = {
            "accuracy": overall_accuracy,
            "total_evaluated": total_evaluated,
            "correct_predictions": correct_predictions
        }
        
        # Add per-gender accuracy
        for gender in ["Male", "Female"]:
            if gender_accuracy[gender]["total"] > 0:
                acc = gender_accuracy[gender]["correct"] / gender_accuracy[gender]["total"]
                metrics[f"{gender.lower()}_accuracy"] = acc
            else:
                metrics[f"{gender.lower()}_accuracy"] = 0.0
        
        return metrics