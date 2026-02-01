"""
Strix-Turbo NPU Client Package Setup

Install with: pip install .
"""

from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as f:
    long_description = f.read()

setup(
    name="strix-npu",
    version="0.1.0",
    author="Strix-Turbo Project",
    author_email="strix-turbo@example.com",
    description="NPU client for WSL2 - access AMD XDNA NPU from Linux",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/strix-turbo/wsl",
    packages=find_packages(),
    classifiers=[
        "Development Status :: 3 - Alpha",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Operating System :: POSIX :: Linux",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Topic :: Scientific/Engineering :: Artificial Intelligence",
        "Topic :: System :: Hardware",
    ],
    python_requires=">=3.8",
    install_requires=[
        # No required dependencies - uses stdlib only
    ],
    extras_require={
        "dev": [
            "pytest>=7.0.0",
            "pytest-asyncio>=0.21.0",
            "black>=23.0.0",
            "mypy>=1.0.0",
        ],
    },
    entry_points={
        "console_scripts": [
            "strix-npu-test=strix_npu.client:main",
        ],
    },
)
