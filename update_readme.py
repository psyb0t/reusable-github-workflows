import os

# Directory to list
files_dir = ".github/workflows"

# Path to the README file
readme_path = "README.md"

# Excluded files
excluded_files = ["update-readme.yml"]

# Marker to indicate where to insert the file list in the README
start_marker = "<!-- SCRIPTS_START -->"
end_marker = "<!-- SCRIPTS_END -->"

# Generate the list of files as Markdown links
file_list = "\n".join(
    [
        f"- [{file}]({files_dir}/{file})"
        for file in os.listdir(files_dir)
        if os.path.isfile(os.path.join(files_dir, file) and file not in excluded_files)
    ]
)

# Read the current README file
with open(readme_path, "r") as readme_file:
    readme_contents = readme_file.read()

# Find the start and end markers
start_index = readme_contents.find(start_marker)
end_index = readme_contents.find(end_marker)

if start_index == -1 or end_index == -1:
    print("Markers not found in README file.")
    exit(1)

# Update the README contents
new_readme_contents = (
    readme_contents[: start_index + len(start_marker)]
    + "\n"
    + file_list
    + "\n"
    + readme_contents[end_index:]
)

# Write the new contents back to the README file
with open(readme_path, "w") as readme_file:
    readme_file.write(new_readme_contents)
