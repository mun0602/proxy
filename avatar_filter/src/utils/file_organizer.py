"""
File Organizer for sorting images into appropriate directory structure
"""
import logging
import shutil
from pathlib import Path
from typing import Dict, List, Tuple, Any
import os

# Handle imports - try relative first, then absolute for standalone usage
try:
    from ..processors.classification_engine import ClassificationResult
except ImportError:
    from processors.classification_engine import ClassificationResult

class FileOrganizer:
    """Organizes processed images into the specified directory structure"""
    
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.output_config = config.get("output", {})
        self.base_directory = self.output_config.get("base_directory", "output")
        self.structure = self.output_config.get("structure", [
            "Male/Suitable",
            "Male/Not_Suitable",
            "Female/Suitable", 
            "Female/Not_Suitable",
            "Uncertain/Suitable",
            "Uncertain/Not_Suitable"
        ])
    
    def create_directory_structure(self, base_path: str = None) -> bool:
        """
        Create the output directory structure
        
        Args:
            base_path: Base path for output (uses config default if None)
            
        Returns:
            bool: True if successful
        """
        try:
            if base_path is None:
                base_path = self.base_directory
            
            base_path = Path(base_path)
            
            # Create base directory
            base_path.mkdir(parents=True, exist_ok=True)
            
            # Create all subdirectories
            for folder in self.structure:
                folder_path = base_path / folder
                folder_path.mkdir(parents=True, exist_ok=True)
                logging.debug(f"Created directory: {folder_path}")
            
            logging.info(f"Directory structure created at: {base_path}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to create directory structure: {str(e)}")
            return False
    
    def get_target_directory(self, result: ClassificationResult, base_path: str = None) -> Path:
        """
        Determine target directory for an image based on classification result
        
        Args:
            result: Classification result
            base_path: Base output path
            
        Returns:
            Path to target directory
        """
        if base_path is None:
            base_path = self.base_directory
        
        base_path = Path(base_path)
        
        # Determine gender folder
        gender = result.gender
        
        # Determine suitability folder
        suitability = "Suitable" if result.is_suitable else "Not_Suitable"
        
        # Construct path
        target_path = base_path / gender / suitability
        
        return target_path
    
    def organize_image(self, image_path: str, result: ClassificationResult, 
                      base_path: str = None, copy_files: bool = True) -> Tuple[bool, str]:
        """
        Organize a single image into the appropriate directory
        
        Args:
            image_path: Source image path
            result: Classification result
            base_path: Base output path
            copy_files: If True, copy files; if False, move files
            
        Returns:
            Tuple of (success, target_path)
        """
        try:
            source_path = Path(image_path)
            
            if not source_path.exists():
                logging.error(f"Source image not found: {image_path}")
                return False, ""
            
            # Get target directory
            target_dir = self.get_target_directory(result, base_path)
            
            # Ensure target directory exists
            target_dir.mkdir(parents=True, exist_ok=True)
            
            # Generate target file path
            target_path = target_dir / source_path.name
            
            # Handle filename conflicts
            counter = 1
            original_target = target_path
            while target_path.exists():
                stem = original_target.stem
                suffix = original_target.suffix
                target_path = target_dir / f"{stem}_{counter}{suffix}"
                counter += 1
            
            # Copy or move file
            if copy_files:
                shutil.copy2(source_path, target_path)
                operation = "copied"
            else:
                shutil.move(str(source_path), str(target_path))
                operation = "moved"
            
            logging.debug(f"Image {operation} to: {target_path}")
            return True, str(target_path)
            
        except Exception as e:
            logging.error(f"Failed to organize image '{image_path}': {str(e)}")
            return False, ""
    
    def organize_batch(self, results: List[Tuple[str, ClassificationResult]], 
                      base_path: str = None, copy_files: bool = True) -> Dict[str, Any]:
        """
        Organize a batch of images
        
        Args:
            results: List of (image_path, ClassificationResult) tuples
            base_path: Base output path
            copy_files: If True, copy files; if False, move files
            
        Returns:
            Dictionary with organization statistics
        """
        if base_path is None:
            base_path = self.base_directory
        
        # Create directory structure
        if not self.create_directory_structure(base_path):
            return {"success": False, "error": "Failed to create directory structure"}
        
        # Track statistics
        stats = {
            "total_processed": 0,
            "successful": 0,
            "failed": 0,
            "by_category": {},
            "failed_files": [],
            "success": True
        }
        
        # Initialize category counters
        for gender in ["Male", "Female", "Uncertain"]:
            for suitability in ["Suitable", "Not_Suitable"]:
                category = f"{gender}/{suitability}"
                stats["by_category"][category] = 0
        
        # Process each image
        for image_path, result in results:
            stats["total_processed"] += 1
            
            success, target_path = self.organize_image(image_path, result, base_path, copy_files)
            
            if success:
                stats["successful"] += 1
                
                # Update category counter
                gender = result.gender
                suitability = "Suitable" if result.is_suitable else "Not_Suitable"
                category = f"{gender}/{suitability}"
                stats["by_category"][category] += 1
                
            else:
                stats["failed"] += 1
                stats["failed_files"].append(image_path)
        
        logging.info(f"Batch organization complete: {stats['successful']}/{stats['total_processed']} successful")
        
        return stats
    
    def create_summary_report(self, results: List[Tuple[str, ClassificationResult]], 
                            stats: Dict[str, Any], output_path: str = None) -> bool:
        """
        Create a summary report of the organization process
        
        Args:
            results: Classification results
            stats: Organization statistics
            output_path: Path for the report file
            
        Returns:
            bool: True if successful
        """
        try:
            if output_path is None:
                output_path = Path(self.base_directory) / "summary_report.txt"
            else:
                output_path = Path(output_path)
            
            with open(output_path, 'w', encoding='utf-8') as f:
                f.write("=== Avatar Image Filter Summary Report ===\n\n")
                
                # Processing Statistics
                f.write("PROCESSING STATISTICS:\n")
                f.write(f"Total images processed: {stats['total_processed']}\n")
                f.write(f"Successfully organized: {stats['successful']}\n")
                f.write(f"Failed to organize: {stats['failed']}\n")
                f.write(f"Success rate: {(stats['successful']/stats['total_processed']*100):.1f}%\n\n")
                
                # Category Breakdown
                f.write("CATEGORY BREAKDOWN:\n")
                for category, count in stats["by_category"].items():
                    f.write(f"{category}: {count} images\n")
                f.write("\n")
                
                # Gender Distribution
                male_total = stats["by_category"]["Male/Suitable"] + stats["by_category"]["Male/Not_Suitable"]
                female_total = stats["by_category"]["Female/Suitable"] + stats["by_category"]["Female/Not_Suitable"]
                uncertain_total = stats["by_category"]["Uncertain/Suitable"] + stats["by_category"]["Uncertain/Not_Suitable"]
                
                f.write("GENDER DISTRIBUTION:\n")
                f.write(f"Male: {male_total} ({(male_total/stats['total_processed']*100):.1f}%)\n")
                f.write(f"Female: {female_total} ({(female_total/stats['total_processed']*100):.1f}%)\n")
                f.write(f"Uncertain: {uncertain_total} ({(uncertain_total/stats['total_processed']*100):.1f}%)\n\n")
                
                # Suitability Analysis
                total_suitable = (stats["by_category"]["Male/Suitable"] + 
                                stats["by_category"]["Female/Suitable"] + 
                                stats["by_category"]["Uncertain/Suitable"])
                
                f.write("SUITABILITY ANALYSIS:\n")
                f.write(f"Suitable for avatar: {total_suitable} ({(total_suitable/stats['total_processed']*100):.1f}%)\n")
                f.write(f"Not suitable: {stats['total_processed']-total_suitable} ({((stats['total_processed']-total_suitable)/stats['total_processed']*100):.1f}%)\n\n")
                
                # Quality Metrics
                if results:
                    confidences = [r[1].gender_confidence for r in results]
                    suitability_scores = [r[1].suitability_score for r in results]
                    face_ratios = [r[1].face_ratio for r in results]
                    
                    f.write("QUALITY METRICS:\n")
                    f.write(f"Average gender confidence: {sum(confidences)/len(confidences):.3f}\n")
                    f.write(f"Average suitability score: {sum(suitability_scores)/len(suitability_scores):.3f}\n")
                    f.write(f"Average face ratio: {sum(face_ratios)/len(face_ratios):.3f}\n\n")
                
                # Failed Files
                if stats["failed_files"]:
                    f.write("FAILED FILES:\n")
                    for failed_file in stats["failed_files"]:
                        f.write(f"- {failed_file}\n")
                    f.write("\n")
                
                # Directory Structure
                f.write("OUTPUT DIRECTORY STRUCTURE:\n")
                f.write(f"{self.base_directory}/\n")
                for folder in self.structure:
                    count = stats["by_category"].get(folder, 0)
                    f.write(f"├── {folder}/ ({count} images)\n")
            
            logging.info(f"Summary report created: {output_path}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to create summary report: {str(e)}")
            return False
    
    def clean_empty_directories(self, base_path: str = None) -> int:
        """
        Remove empty directories from the output structure
        
        Args:
            base_path: Base path to clean
            
        Returns:
            Number of directories removed
        """
        if base_path is None:
            base_path = self.base_directory
        
        base_path = Path(base_path)
        removed_count = 0
        
        try:
            # Walk through all directories bottom-up
            for dirpath, dirnames, filenames in os.walk(base_path, topdown=False):
                dirpath = Path(dirpath)
                
                # Skip the base directory
                if dirpath == base_path:
                    continue
                
                # Check if directory is empty
                if not any(dirpath.iterdir()):
                    dirpath.rmdir()
                    removed_count += 1
                    logging.debug(f"Removed empty directory: {dirpath}")
            
            if removed_count > 0:
                logging.info(f"Cleaned {removed_count} empty directories")
            
            return removed_count
            
        except Exception as e:
            logging.error(f"Error cleaning directories: {str(e)}")
            return 0
    
    def get_organization_preview(self, results: List[Tuple[str, ClassificationResult]]) -> Dict[str, List[str]]:
        """
        Generate a preview of how files would be organized without actually moving them
        
        Args:
            results: Classification results
            
        Returns:
            Dictionary mapping target directories to lists of source files
        """
        preview = {}
        
        for image_path, result in results:
            target_dir = self.get_target_directory(result)
            target_dir_str = str(target_dir)
            
            if target_dir_str not in preview:
                preview[target_dir_str] = []
            
            preview[target_dir_str].append(image_path)
        
        return preview