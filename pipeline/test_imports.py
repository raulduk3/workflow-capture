"""Quick test to see which import is causing the hang"""
import sys
print(f"Python {sys.version}")
print("Testing imports...")

try:
    print("  [1/6] argparse...", end="", flush=True)
    import argparse
    print(" OK")
    
    print("  [2/6] datetime/pathlib...", end="", flush=True)
    from datetime import datetime
    from pathlib import Path
    print(" OK")
    
    print("  [3/6] config...", end="", flush=True)
    from config import CONVERSION_CSV, MP4_DIR, OUTPUT_DIR
    print(" OK")
    
    print("  [4/6] csv_manager...", end="", flush=True)
    from csv_manager import load_processed_ids
    print(" OK")
    
    print("  [5/6] filename_parser...", end="", flush=True)
    from filename_parser import load_converted_sessions
    print(" OK")
    
    print("  [6/6] gemini_analyzer...", end="", flush=True)
    from gemini_analyzer import analyze_video
    print(" OK")
    
    print("\nAll imports successful!")
    print(f"Output dir: {OUTPUT_DIR}")
    print(f"CSV: {CONVERSION_CSV}")
    
except Exception as e:
    print(f" FAILED!")
    print(f"\nERROR: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
