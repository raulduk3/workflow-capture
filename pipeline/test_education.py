"""Quick smoke test for education pipeline additions."""
import sys
sys.path.insert(0, '.')

from config import (
    EDUCATION_CSV, EDUCATION_ANALYSES_DIR, EDUCATION_PROCESSING_LOG,
    EDUCATION_REJECTED_LOG, EDUCATION_CSV_COLUMNS, MIN_EDUCATION_DURATION_SEC,
    CSV_COLUMNS
)
print('Config OK')
print(f'  EDUCATION_CSV_COLUMNS count: {len(EDUCATION_CSV_COLUMNS)}')
print(f'  CSV_COLUMNS count: {len(CSV_COLUMNS)}')

from csv_manager import (
    append_education_row, build_education_row, save_education_markdown,
    mark_education_rejected, load_education_rejected_ids,
    append_row, build_row, save_analysis_markdown
)
print('CSV Manager OK')

from gemini_analyzer import (
    analyze_video_education, analyze_video,
    EDUCATION_ANALYSIS_PROMPT, EDUCATION_EXTRACTION_PROMPT,
    ANALYSIS_PROMPT, EXTRACTION_PROMPT,
    _check_education_quality, _parse_education_json_response,
    _parse_education_markdown_response, _empty_education_structured,
    _check_analysis_quality
)
print('Gemini Analyzer OK')

from education_report_generator import generate_education_report
print('Education Report Generator OK')

# Functional tests
good = _check_education_quality({
    'workflow_summary': 'User was entering data into Excel spreadsheet',
    'ai_assistable_moments': '[{"moment": "data entry"}]',
    'recommended_training_modules': '["Excel basics"]',
})
assert good['is_useful'] is True

bad = _check_education_quality({
    'workflow_summary': '',
    'ai_assistable_moments': '[]',
    'recommended_training_modules': '[]',
})
assert bad['is_useful'] is False
print('Education quality checks OK')

parsed = _parse_education_json_response(
    '{"workflow_summary": "Test", "skill_level": "intermediate", '
    '"learning_category": "spreadsheet_skills", "time_save_opportunity": "significant", '
    '"ai_assistable_moments": [], "missed_tool_features": [], '
    '"manual_effort_description": "Lots of typing", "skill_level_reasoning": "Uses some shortcuts", '
    '"recommended_training_modules": ["Excel VLOOKUP"], "example_ai_prompt": "Summarize this data"}',
    'test'
)
assert parsed['skill_level'] == 'intermediate'
assert parsed['learning_category'] == 'spreadsheet_skills'
assert parsed['time_save_opportunity'] == 'significant'
print('Education JSON parser OK')

existing = _check_analysis_quality({
    'primary_app': 'Excel',
    'automation_score': 0.7,
    'sop_step_count': 5,
    'workflow_description': 'User enters data into spreadsheet for reporting',
})
assert existing['is_useful'] is True
print('Existing quality check untouched OK')

print('\nALL TESTS PASSED')
