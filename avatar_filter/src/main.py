"""
Main CLI interface for the Avatar Image Filter Tool
"""
import logging
import sys
import time
from pathlib import Path
from typing import List, Optional
import click
from tqdm import tqdm

# Add the src directory to Python path
sys.path.insert(0, str(Path(__file__).parent))

from models.model_manager import ModelManager
from processors.image_processor import ImageProcessor
from processors.classification_engine import ClassificationEngine
from utils.file_organizer import FileOrganizer
from utils.config_manager import ConfigManager, setup_logging, create_default_config

@click.command()
@click.option('--input-dir', '-i', required=True, type=click.Path(exists=True), 
              help='Input directory containing images to process')
@click.option('--output-dir', '-o', default='output', 
              help='Output directory for organized images (default: output)')
@click.option('--config', '-c', type=click.Path(), 
              help='Path to configuration file (will create default if not specified)')
@click.option('--copy/--move', default=True, 
              help='Copy files to output (default) or move them')
@click.option('--recursive/--no-recursive', default=True,
              help='Search input directory recursively (default: True)')
@click.option('--log-level', default='INFO', 
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR']),
              help='Logging level (default: INFO)')
@click.option('--log-file', type=click.Path(),
              help='Optional log file path')
@click.option('--preview/--no-preview', default=False,
              help='Preview organization without moving files')
@click.option('--batch-size', default=32, type=int,
              help='Batch size for processing (default: 32)')
def main(input_dir: str, output_dir: str, config: Optional[str], copy: bool, 
         recursive: bool, log_level: str, log_file: Optional[str], 
         preview: bool, batch_size: int):
    """
    AI-powered Avatar Image Filter Tool
    
    Classifies images by gender and avatar suitability using Intel NPU acceleration.
    """
    # Setup logging
    setup_logging(log_level, log_file)
    logger = logging.getLogger(__name__)
    
    # Print banner
    click.echo("=" * 60)
    click.echo("AI-powered Avatar Image Filter Tool")
    click.echo("Intel NPU Accelerated Classification")
    click.echo("=" * 60)
    
    try:
        # Load or create configuration
        config_manager = ConfigManager()
        
        if config and Path(config).exists():
            click.echo(f"Loading configuration from: {config}")
            config_manager.load_config(config)
        else:
            click.echo("Using default configuration")
            config_manager.config = create_default_config()
            
            # Save default config if path specified
            if config:
                config_manager.save_config(config)
                click.echo(f"Default configuration saved to: {config}")
        
        # Validate configuration
        is_valid, issues = config_manager.validate_config()
        if not is_valid:
            click.echo("Configuration validation failed:")
            for issue in issues:
                click.echo(f"  - {issue}")
            return
        
        # Update output directory in config
        config_manager.set('output.base_directory', output_dir)
        config_manager.set('processing.batch_size', batch_size)
        
        # Initialize components
        click.echo("\nInitializing AI models...")
        
        model_manager = ModelManager(config_manager.config)
        image_processor = ImageProcessor(config_manager.config)
        classification_engine = ClassificationEngine(model_manager, image_processor, config_manager.config)
        file_organizer = FileOrganizer(config_manager.config)
        
        # Load models
        click.echo("Loading AI models for Intel NPU...")
        if not model_manager.load_all_models():
            click.echo("Warning: Some models failed to load. Continuing with available models...")
        
        # Find images
        click.echo(f"\nScanning for images in: {input_dir}")
        image_files = image_processor.find_images_in_directory(input_dir, recursive)
        
        if not image_files:
            click.echo("No supported image files found.")
            return
        
        click.echo(f"Found {len(image_files)} image files")
        
        # Process images
        click.echo("\nProcessing images...")
        
        start_time = time.time()
        
        # Create progress bar
        with tqdm(total=len(image_files), desc="Classifying images") as pbar:
            results = []
            
            # Process in batches
            for i in range(0, len(image_files), batch_size):
                batch = image_files[i:i+batch_size]
                batch_results = classification_engine.batch_classify(batch)
                results.extend(batch_results)
                pbar.update(len(batch))
        
        processing_time = time.time() - start_time
        
        # Display results summary
        click.echo(f"\nProcessing completed in {processing_time:.2f} seconds")
        click.echo(f"Average time per image: {processing_time/len(image_files):.3f} seconds")
        
        # Generate classification summary
        summary = classification_engine.get_classification_summary(results)
        
        click.echo("\n" + "=" * 40)
        click.echo("CLASSIFICATION SUMMARY")
        click.echo("=" * 40)
        click.echo(f"Total images: {summary['total_images']}")
        click.echo(f"Suitable for avatar: {summary['total_suitable']} ({summary['suitability_rate']*100:.1f}%)")
        click.echo()
        click.echo("Gender distribution:")
        for gender, count in summary['gender_distribution'].items():
            percentage = summary['gender_percentages'][gender]
            click.echo(f"  {gender}: {count} ({percentage:.1f}%)")
        click.echo()
        click.echo("Average metrics:")
        click.echo(f"  Gender confidence: {summary['average_metrics']['gender_confidence']:.3f}")
        click.echo(f"  Suitability score: {summary['average_metrics']['suitability_score']:.3f}")
        click.echo(f"  Face ratio: {summary['average_metrics']['face_ratio']:.3f}")
        
        if preview:
            # Show organization preview
            click.echo("\n" + "=" * 40)
            click.echo("ORGANIZATION PREVIEW")
            click.echo("=" * 40)
            
            preview_data = file_organizer.get_organization_preview(results)
            for target_dir, files in preview_data.items():
                click.echo(f"{target_dir}: {len(files)} files")
            
            click.echo("\nPreview mode - no files were moved.")
        else:
            # Organize files
            click.echo(f"\n{'Copying' if copy else 'Moving'} files to output directory...")
            
            org_stats = file_organizer.organize_batch(results, output_dir, copy)
            
            if org_stats['success']:
                click.echo(f"Organization completed: {org_stats['successful']}/{org_stats['total_processed']} files")
                
                if org_stats['failed'] > 0:
                    click.echo(f"Failed to organize {org_stats['failed']} files")
                
                # Create summary report
                report_path = Path(output_dir) / "summary_report.txt"
                if file_organizer.create_summary_report(results, org_stats, report_path):
                    click.echo(f"Summary report created: {report_path}")
                
                # Clean empty directories
                cleaned = file_organizer.clean_empty_directories(output_dir)
                if cleaned > 0:
                    click.echo(f"Cleaned {cleaned} empty directories")
                
                click.echo("\n" + "=" * 40)
                click.echo("OUTPUT STRUCTURE")
                click.echo("=" * 40)
                click.echo(f"{output_dir}/")
                for category, count in org_stats['by_category'].items():
                    if count > 0:
                        click.echo(f"├── {category}/ ({count} images)")
            else:
                click.echo("Organization failed!")
                return
        
        click.echo("\n" + "=" * 60)
        click.echo("Processing completed successfully!")
        click.echo("=" * 60)
        
    except KeyboardInterrupt:
        click.echo("\nProcessing interrupted by user.")
    except Exception as e:
        logger.error(f"Processing failed: {str(e)}")
        click.echo(f"Error: {str(e)}")
        raise

@click.command()
@click.option('--output', '-o', default='config/config.yaml',
              help='Output path for configuration file')
def create_config(output: str):
    """Create a default configuration file"""
    try:
        config = create_default_config()
        
        output_path = Path(output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        config_manager = ConfigManager()
        config_manager.config = config
        
        if config_manager.save_config(output):
            click.echo(f"Default configuration created: {output}")
        else:
            click.echo("Failed to create configuration file")
            
    except Exception as e:
        click.echo(f"Error creating configuration: {str(e)}")

@click.group()
def cli():
    """AI Avatar Image Filter Tool - Intel NPU Accelerated"""
    pass

# Add commands to group
cli.add_command(main, name='process')
cli.add_command(create_config, name='create-config')

if __name__ == '__main__':
    cli()